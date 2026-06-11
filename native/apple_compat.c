/* apple_compat.c - macOS host glue for schwung's shadow UI.
 *
 * Plays the role the LD_PRELOAD shim plays on the Move: creates the SHM
 * segments, seeds control/ui state, answers param requests (stub for now —
 * the audio engine lands in phase 2), and bridges MIDI/display to Swift.
 * Also implements the path-remap wrappers injected into upstream sources by
 * apple_compat_overrides.h ("/data/UserData" → user-chosen data root).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <dirent.h>
#include <limits.h>
#include <utime.h>
#include <sys/time.h>

#include <dlfcn.h>
#include <TargetConditionals.h>

#include "host/shadow_constants.h"
#include "include/schwung_apple.h"
#include "apple_internal.h"

#define MOVE_DATA_PREFIX "/data/UserData"

static char g_data_root[PATH_MAX] = "";   /* replaces MOVE_DATA_PREFIX */
static size_t g_data_root_len = 0;

void schwung_set_data_root(const char *data_root) {
    /* Canonicalize so reverse-mapping matches realpath() output
     * (e.g. /tmp → /private/tmp). */
    if (!realpath(data_root, g_data_root)) {
        strncpy(g_data_root, data_root, sizeof(g_data_root) - 1);
        g_data_root[sizeof(g_data_root) - 1] = '\0';
    }
    size_t len = strlen(g_data_root);
    while (len > 1 && g_data_root[len - 1] == '/') g_data_root[--len] = '\0';
    g_data_root_len = len;
}

/* ============================================================================
 * Path remapping
 * ============================================================================ */

static const char *remap_path(const char *path, char *buf, size_t buf_len) {
    if (!path || g_data_root_len == 0) return path;
    size_t plen = strlen(MOVE_DATA_PREFIX);
    if (strncmp(path, MOVE_DATA_PREFIX, plen) != 0) return path;
    if (path[plen] != '\0' && path[plen] != '/') return path;
    snprintf(buf, buf_len, "%s%s", g_data_root, path + plen);
    return buf;
}

/* Real path → virtual path, so validate_path()-style prefix checks in
 * upstream code keep working on realpath() output. */
static void unmap_path(char *path) {
    if (g_data_root_len == 0) return;
    if (strncmp(path, g_data_root, g_data_root_len) != 0) return;
    if (path[g_data_root_len] != '\0' && path[g_data_root_len] != '/') return;
    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof(tmp), MOVE_DATA_PREFIX "%s", path + g_data_root_len);
    if (n < 0 || n >= PATH_MAX) return;
    /* The virtual prefix is shorter than the real root, so this shrinks in place. */
    memcpy(path, tmp, (size_t)n + 1);
}

FILE *schwung_compat_fopen(const char *path, const char *mode) {
    char buf[PATH_MAX];
    return fopen(remap_path(path, buf, sizeof(buf)), mode);
}

int schwung_compat_open(const char *path, int flags, ...) {
    char buf[PATH_MAX];
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return open(remap_path(path, buf, sizeof(buf)), flags, mode);
}

int schwung_compat_stat(const char *path, struct stat *st) {
    char buf[PATH_MAX];
    return stat(remap_path(path, buf, sizeof(buf)), st);
}

int schwung_compat_lstat(const char *path, struct stat *st) {
    char buf[PATH_MAX];
    return lstat(remap_path(path, buf, sizeof(buf)), st);
}

int schwung_compat_access(const char *path, int mode) {
    char buf[PATH_MAX];
    return access(remap_path(path, buf, sizeof(buf)), mode);
}

DIR *schwung_compat_opendir(const char *path) {
    char buf[PATH_MAX];
    return opendir(remap_path(path, buf, sizeof(buf)));
}

int schwung_compat_mkdir(const char *path, mode_t mode) {
    char buf[PATH_MAX];
    return mkdir(remap_path(path, buf, sizeof(buf)), mode);
}

int schwung_compat_rmdir(const char *path) {
    char buf[PATH_MAX];
    return rmdir(remap_path(path, buf, sizeof(buf)));
}

int schwung_compat_remove(const char *path) {
    char buf[PATH_MAX];
    return remove(remap_path(path, buf, sizeof(buf)));
}

int schwung_compat_unlink(const char *path) {
    char buf[PATH_MAX];
    return unlink(remap_path(path, buf, sizeof(buf)));
}

int schwung_compat_rename(const char *from, const char *to) {
    char bf[PATH_MAX], bt[PATH_MAX];
    return rename(remap_path(from, bf, sizeof(bf)), remap_path(to, bt, sizeof(bt)));
}

char *schwung_compat_realpath(const char *path, char *resolved) {
    char buf[PATH_MAX];
    char *r = realpath(remap_path(path, buf, sizeof(buf)), resolved);
    if (r) unmap_path(r);
    return r;
}

int schwung_compat_utimes(const char *path, const struct timeval *times) {
    char buf[PATH_MAX];
    return utimes(remap_path(path, buf, sizeof(buf)), times);
}

ssize_t schwung_compat_readlink(const char *path, char *out, size_t out_len) {
    char buf[PATH_MAX];
    return readlink(remap_path(path, buf, sizeof(buf)), out, out_len);
}

int schwung_compat_symlink(const char *target, const char *linkpath) {
    char bt[PATH_MAX], bl[PATH_MAX];
    return symlink(remap_path(target, bt, sizeof(bt)), remap_path(linkpath, bl, sizeof(bl)));
}

int schwung_compat_truncate(const char *path, off_t length) {
    char buf[PATH_MAX];
    return truncate(remap_path(path, buf, sizeof(buf)), length);
}

/* On-device iOS only dlopens signed code inside the app bundle. When Swift
 * sets this, modules/<...>/dsp.so redirects to Frameworks/schwung_<...>.dylib. */
static char g_dylib_dir[PATH_MAX];

void schwung_set_dylib_dir(const char *dir) {
    snprintf(g_dylib_dir, sizeof(g_dylib_dir), "%s", dir ? dir : "");
}

void *schwung_dlopen_module(const char *path, int mode) {
    const char *m;
    /* chain loads siblings via "modules/chain/../<cat>/<id>/dsp.so" — resolve
     * the dots or the redirect match below misses. */
    char canon[PATH_MAX];
    if (g_dylib_dir[0] && realpath(path, canon)) path = canon;
    if (g_dylib_dir[0] && (m = strstr(path, "/modules/")) != NULL) {
        char name[256], full[PATH_MAX];
        snprintf(name, sizeof(name), "%s", m + 9);
        /* key on the module DIR: chain loads "dsp.so" for synths but
         * "<id>.so" for in-chain audio FX — same binary either way */
        char *suffix = strrchr(name, '/');
        if (suffix && strstr(suffix, ".so")) {
            *suffix = '\0';
            for (char *c = name; *c; c++) if (*c == '/') *c = '_';
            snprintf(full, sizeof(full), "%s/schwung_%s.dylib", g_dylib_dir, name);
            if (access(full, F_OK) == 0) return dlopen(full, mode);
        }
    }
    return dlopen(path, mode);
}

void *schwung_compat_dlopen(const char *path, int mode) {
    char buf[PATH_MAX];
    return schwung_dlopen_module(remap_path(path, buf, sizeof(buf)), mode);
}

/* POSIX named SHM is unavailable inside the iOS sandbox; everything is
 * in-process here anyway, so file-backed mmap regions are equivalent. */
int schwung_compat_shm_open(const char *name, int oflag, int mode) {
#if TARGET_OS_IPHONE
    char dir[PATH_MAX], path[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/.shm", g_data_root);
    mkdir(dir, 0755);
    snprintf(path, sizeof(path), "%s%s", dir, name);  /* name begins with '/' */
    return open(path, oflag, (mode_t)mode);
#else
    return shm_open(name, oflag, (mode_t)mode);
#endif
}

int schwung_compat_shm_unlink(const char *name) {
#if TARGET_OS_IPHONE
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/.shm%s", g_data_root, name);
    return unlink(path);
#else
    return shm_unlink(name);
#endif
}

int schwung_compat_fork_unavailable(void) {
    errno = ENOSYS;
    return -1;
}

int schwung_compat_system_unavailable(const char *cmd) {
    (void)cmd;
    errno = ENOSYS;
    return -1;
}

int schwung_compat_execvp(const char *file, char *const argv[]) {
    char fbuf[PATH_MAX];
    int argc = 0;
    while (argv[argc]) argc++;
    char **remapped = calloc((size_t)argc + 1, sizeof(char *));
    char (*bufs)[PATH_MAX] = calloc((size_t)argc, PATH_MAX);
    if (!remapped || !bufs) _exit(127);
    for (int i = 0; i < argc; i++) {
        remapped[i] = (char *)remap_path(argv[i], bufs[i], PATH_MAX);
    }
    remapped[argc] = NULL;
    return execvp(remap_path(file, fbuf, sizeof(fbuf)), remapped);
}

/* ============================================================================
 * SHM creation + seeding (the shim's job on-device)
 * ============================================================================ */

typedef struct {
    const char *name;
    size_t size;
} shm_def_t;

static shadow_control_t *g_control = NULL;
static shadow_ui_state_t *g_ui_state = NULL;
static shadow_param_t *g_param = NULL;
static uint8_t *g_ui_midi = NULL;
static uint8_t *g_display = NULL;
static shadow_midi_out_t *g_midi_out = NULL;
static shadow_midi_dsp_t *g_midi_dsp = NULL;
static shadow_overlay_state_t *g_overlay_state = NULL;

shadow_param_t *schwung_shm_param(void) { return g_param; }
shadow_control_t *schwung_shm_control(void) { return g_control; }
shadow_ui_state_t *schwung_shm_ui_state(void) { return g_ui_state; }
shadow_midi_dsp_t *schwung_shm_midi_dsp(void) { return g_midi_dsp; }
shadow_overlay_state_t *schwung_shm_overlay(void) { return g_overlay_state; }

const char *schwung_remap(const char *path, char *buf, size_t buf_len) {
    return remap_path(path, buf, buf_len);
}

static void *create_segment(const char *name, size_t size) {
    schwung_compat_shm_unlink(name);  /* drop any stale segment from a previous run */
    int fd = schwung_compat_shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0666);
    if (fd < 0) {
        fprintf(stderr, "schwung_apple: shm_open(%s) failed: %s\n", name, strerror(errno));
        return NULL;
    }
    if (ftruncate(fd, (off_t)size) != 0) {
        fprintf(stderr, "schwung_apple: ftruncate(%s, %zu) failed: %s\n", name, size, strerror(errno));
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        fprintf(stderr, "schwung_apple: mmap(%s) failed: %s\n", name, strerror(errno));
        return NULL;
    }
    memset(p, 0, size);
    return p;
}

static int create_all_segments(void) {
    g_display = create_segment(SHM_SHADOW_DISPLAY, DISPLAY_BUFFER_SIZE);
    g_ui_midi = create_segment(SHM_SHADOW_UI_MIDI, MIDI_BUFFER_SIZE);
    g_control = create_segment(SHM_SHADOW_CONTROL, CONTROL_BUFFER_SIZE);
    g_ui_state = create_segment(SHM_SHADOW_UI, SHADOW_UI_BUFFER_SIZE);
    g_param = create_segment(SHM_SHADOW_PARAM, SHADOW_PARAM_BUFFER_SIZE);
    g_midi_out = create_segment(SHM_SHADOW_MIDI_OUT, sizeof(shadow_midi_out_t));
    g_midi_dsp = create_segment(SHM_SHADOW_MIDI_DSP, sizeof(shadow_midi_dsp_t));
    void *ok = g_display;
    ok = ok && g_ui_midi && g_control && g_ui_state && g_param && g_midi_out ? (void *)1 : NULL;
    if (!g_midi_dsp) ok = NULL;
    if (!create_segment(SHM_SHADOW_MIDI_INJECT, sizeof(shadow_midi_inject_t))) ok = NULL;
    if (!create_segment(SHM_SHADOW_EXT_MIDI_REMAP, sizeof(schwung_ext_midi_remap_t))) ok = NULL;
    if (!create_segment(SHM_SHADOW_SCREENREADER, SHADOW_SCREENREADER_BUFFER_SIZE)) ok = NULL;
    g_overlay_state = create_segment(SHM_SHADOW_OVERLAY, SHADOW_OVERLAY_BUFFER_SIZE);
    if (!g_overlay_state) ok = NULL;
    create_segment(SHM_DISPLAY_LIVE, 4096);  /* optional on-device; harmless */
    return ok ? 0 : -1;
}

static void seed_state(void) {
    g_control->display_mode = 1;          /* shadow UI always visible here */
    g_control->shadow_ui_trigger = 2;     /* Both */
    g_control->speaker_active = 1;
    g_control->move_ui_mode = 1;          /* session */
    g_control->skipback_seconds = 30;

    g_ui_state->version = 1;
    g_ui_state->slot_count = SHADOW_UI_SLOTS;
    for (int i = 0; i < SHADOW_UI_SLOTS; i++) {
        g_ui_state->slot_channels[i] = (uint8_t)(i + 1);
        g_ui_state->slot_volumes[i] = 100;
        g_ui_state->slot_forward_ch[i] = -1;
        g_ui_state->slot_names[i][0] = '\0';
    }
}

/* ============================================================================
 * Param stub responder — answers as the shim would with all slots empty.
 * Replaced by the real chain engine in phase 2.
 * ============================================================================ */

static volatile int g_threads_running = 0;

static void *param_stub_thread(void *arg) {
    (void)arg;
    while (g_threads_running) {
        if (g_param && g_param->request_type != 0) {
            g_param->result_len = -1;
            g_param->error = 1;
            g_param->response_id = g_param->request_id;
            g_param->response_ready = 1;
            __sync_synchronize();
            g_param->request_type = 0;
        }
        usleep(1000);
    }
    return NULL;
}

/* ============================================================================
 * MIDI bridges
 * ============================================================================ */

void schwung_send_internal_midi(uint8_t status, uint8_t d1, uint8_t d2) {
    if (!g_ui_midi || !g_control || status < 0x80) return;

    /* The shim-side roles Move firmware would otherwise play: track buttons
     * select the active slot; PAD notes play the selected slot's chain.
     * Notes 0-9 are capacitive touch sensors, 16-31 are step buttons —
     * forwarding those would play subsonic junk on the synth. */
    uint8_t type = status & 0xF0;
    if (type == 0xB0 && d1 >= 40 && d1 <= 43 && d2 > 0) {
        g_control->selected_slot = (uint8_t)(43 - d1);  /* CC43=Track1 ... CC40=Track4 */
    }
    int is_pad = (d1 >= 68 && d1 <= 99);
    if (((type == 0x90 || type == 0x80 || type == 0xA0) && is_pad) ||
        type == 0xD0 || type == 0xE0) {
        schwung_audio_play_note(status, d1, d2);
    }

    uint8_t head = (uint8_t)(status >> 4);  /* CIN, cable 0 */
    for (int slot = 0; slot < MIDI_BUFFER_SIZE; slot += 4) {
        if (__atomic_load_n(&g_ui_midi[slot], __ATOMIC_ACQUIRE) == 0) {
            g_ui_midi[slot + 1] = status;
            g_ui_midi[slot + 2] = d1;
            g_ui_midi[slot + 3] = d2;
            __atomic_store_n(&g_ui_midi[slot], head, __ATOMIC_RELEASE);
            g_control->midi_ready++;
            return;
        }
    }
}

void schwung_set_shift_held(int held) {
    if (g_control) g_control->shift_held = (uint8_t)(held ? 1 : 0);
}

void schwung_set_ui_flags(uint8_t mask) {
    if (g_control) g_control->ui_flags |= mask;
}

int schwung_drain_midi_out(uint8_t *out, int max_len) {
    static uint8_t last_ready = 0;
    if (!g_midi_out || g_midi_out->ready == last_ready) return 0;
    last_ready = g_midi_out->ready;
    int len = g_midi_out->write_idx;
    if (len > SHADOW_MIDI_OUT_BUFFER_SIZE) len = SHADOW_MIDI_OUT_BUFFER_SIZE;
    if (len > max_len) len = max_len;
    if (len > 0) memcpy(out, g_midi_out->buffer, (size_t)len);
    __sync_synchronize();
    g_midi_out->write_idx = 0;
    memset(g_midi_out->buffer, 0, SHADOW_MIDI_OUT_BUFFER_SIZE);
    return len;
}

/* ============================================================================
 * Display access
 * ============================================================================ */

const uint8_t *schwung_display_buffer(void) {
    return g_display;
}

uint32_t schwung_display_generation(void) {
    if (!g_display) return 0;
    uint32_t h = 2166136261u;  /* FNV-1a over the 1KB framebuffer */
    for (int i = 0; i < DISPLAY_BUFFER_SIZE; i++) {
        h = (h ^ g_display[i]) * 16777619u;
    }
    return h;
}

/* ============================================================================
 * Engine lifecycle
 * ============================================================================ */

int schwung_shadow_ui_main(int argc, char *argv[]);  /* shadow_ui.c, main renamed */

static pthread_t g_ui_thread;
static pthread_t g_param_thread;
static char g_script_path[PATH_MAX];

static void *shadow_ui_thread(void *arg) {
    (void)arg;
    char *argv[3] = {"shadow_ui", g_script_path, NULL};
    schwung_shadow_ui_main(2, argv);
    return NULL;
}

int schwung_engine_start(const char *script_path) {
    if (g_data_root_len == 0) {
        fprintf(stderr, "schwung_apple: data root not set\n");
        return -1;
    }
    if (create_all_segments() != 0) return -1;
    seed_state();

    strncpy(g_script_path, script_path, sizeof(g_script_path) - 1);
    g_script_path[sizeof(g_script_path) - 1] = '\0';

    g_threads_running = 1;
    /* Real audio engine if the chain DSP module is present; stub otherwise. */
    if (schwung_audio_engine_start() != 0) {
        fprintf(stderr, "schwung_apple: no audio engine, using param stub\n");
        if (pthread_create(&g_param_thread, NULL, param_stub_thread, NULL) != 0) return -1;
    }
    if (pthread_create(&g_ui_thread, NULL, shadow_ui_thread, NULL) != 0) return -1;
    return 0;
}

void schwung_engine_stop(void) {
    if (g_control) g_control->should_exit = 1;
    schwung_audio_engine_stop();
    g_threads_running = 0;
}
