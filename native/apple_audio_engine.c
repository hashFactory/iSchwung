/* apple_audio_engine.c - The shim's audio role, reimplemented for macOS.
 *
 * Drives schwung's unmodified chain DSP (modules/chain/dsp.so, a Mach-O dylib
 * despite the name): 4 slot instances + 4 master FX slots, rendered through a
 * CoreAudio default-output unit. Services the /schwung-param protocol exactly
 * as src/host/shadow_chain_mgmt.c does on-device, so shadow_ui.js needs no
 * changes. Link Audio / sampler / set-pages parts are intentionally absent.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <TargetConditionals.h>
#include <AudioToolbox/AudioToolbox.h>

#include "host/plugin_api_v1.h"
#include "host/audio_fx_api_v2.h"
#include "host/shadow_constants.h"
#include "apple_internal.h"

#define CHAIN_MODULE_DIR "/data/UserData/schwung/modules/chain"
#define CHAIN_DSP_PATH   CHAIN_MODULE_DIR "/dsp.so"
#define SLOT_STATE_FMT   "/data/UserData/schwung/slot_state/slot_%d.json"

/* ============================================================================
 * State
 * ============================================================================ */

typedef struct {
    void *instance;
    int channel;        /* receive: -1 = all, 0-15 */
    int forward;        /* -2 = THRU, -1 = auto, 0-15 */
    int transpose;      /* -12..12 */
    float volume;       /* 0..4 */
    int muted, soloed;
    int active;
} aslot_t;

typedef struct {
    void *handle;
    const audio_fx_api_v2_t *api;
    void *instance;
    int bypassed;
    char id[64];
    char path[512];
} amfx_t;

typedef struct {
    int enabled, shape, rate_div, sync, polarity;
    float rate_hz, depth, phase_offset;
    char target[16];
    char target_param[64];
} alfo_t;

static aslot_t g_slots[SHADOW_CHAIN_INSTANCES];
static amfx_t g_mfx[4];
static alfo_t g_lfos[2] = {
    {0, 0, 0, 0, 0, 1.0f, 0.5f, 0.0f, "fx1", ""},
    {0, 0, 0, 0, 0, 1.0f, 0.5f, 0.0f, "fx1", ""},
};

static void *g_chain_handle = NULL;
static const plugin_api_v2_t *g_plugin = NULL;
static pthread_mutex_t g_dsp = PTHREAD_MUTEX_INITIALIZER;  /* serializes all plugin calls */

static volatile int g_running = 0;
static pthread_t g_ctl_thread;
static AudioUnit g_au = NULL;
static uint8_t g_fake_mailbox[4096];  /* linein etc. read silence from here */
static shadow_overlay_state_t *g_overlay = NULL;

/* ============================================================================
 * host_api_v1_t stub
 * ============================================================================ */

static void host_log(const char *msg) { fprintf(stderr, "chain: %s\n", msg); }
static float host_bpm(void) { return 120.0f; }
static int host_clock_status(void) { return 0; }
static int host_midi_noop(const uint8_t *msg, int len) { (void)msg; (void)len; return 0; }

static int host_slot_recv_channel(void *instance) {
    for (int i = 0; i < SHADOW_CHAIN_INSTANCES; i++) {
        if (g_slots[i].instance == instance) return g_slots[i].channel;
    }
    return -2;
}

static host_api_v1_t g_host_api;

static void init_host_api(void) {
    memset(&g_host_api, 0, sizeof(g_host_api));
    g_host_api.api_version = 1;
    g_host_api.sample_rate = 44100;
    g_host_api.frames_per_block = FRAMES_PER_BLOCK;
    g_host_api.mapped_memory = g_fake_mailbox;
    g_host_api.audio_out_offset = 256;
    g_host_api.audio_in_offset = 2304 % (int)sizeof(g_fake_mailbox);
    g_host_api.log = host_log;
    g_host_api.midi_send_internal = host_midi_noop;
    g_host_api.midi_send_external = host_midi_noop;
    g_host_api.get_clock_status = host_clock_status;
    g_host_api.get_bpm = host_bpm;
    g_host_api.midi_inject_to_move = host_midi_noop;
    g_host_api.slot_recv_channel = host_slot_recv_channel;
}

/* ============================================================================
 * Helpers
 * ============================================================================ */

static void ui_state_sync_slot(int s) {
    shadow_ui_state_t *ui = schwung_shm_ui_state();
    if (!ui) return;
    ui->slot_channels[s] = (uint8_t)(g_slots[s].channel < 0 ? 0 : g_slots[s].channel + 1);
    ui->slot_volumes[s] = (uint16_t)(g_slots[s].volume * 100.0f + 0.5f);
    ui->slot_forward_ch[s] = (int8_t)g_slots[s].forward;
}

static void ui_state_set_name(int s, const char *name) {
    shadow_ui_state_t *ui = schwung_shm_ui_state();
    if (!ui) return;
    strncpy(ui->slot_names[s], name ? name : "", SHADOW_UI_NAME_LEN - 1);
    ui->slot_names[s][SHADOW_UI_NAME_LEN - 1] = '\0';
}

static int get_param_str(void *inst, const char *key, char *buf, int len) {
    buf[0] = '\0';
    if (!g_plugin || !g_plugin->get_param || !inst) return -1;
    int n = g_plugin->get_param(inst, key, buf, len);
    if (n < 0) buf[0] = '\0';
    return n;
}

/* Refresh a slot's active flag + displayed name after a load operation. */
static void slot_probe_loaded(int s) {
    char buf[256];
    static const char *probes[] = {"synth_module", "midi_fx1_module", "midi_fx2_module",
                                   "fx1_module", "fx2_module"};
    g_slots[s].active = 0;
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        if (get_param_str(g_slots[s].instance, probes[i], buf, sizeof(buf)) > 0 && buf[0]) {
            g_slots[s].active = 1;
            break;
        }
    }
    if (get_param_str(g_slots[s].instance, "patch_name", buf, sizeof(buf)) > 0 && buf[0]) {
        ui_state_set_name(s, buf);
    } else if (g_slots[s].active &&
               get_param_str(g_slots[s].instance, "synth_module", buf, sizeof(buf)) > 0) {
        ui_state_set_name(s, buf);
    } else if (!g_slots[s].active) {
        ui_state_set_name(s, "");
    }
}

/* ============================================================================
 * Master FX
 * ============================================================================ */

static void mfx_unload(int f) {
    if (g_mfx[f].instance && g_mfx[f].api && g_mfx[f].api->destroy_instance) {
        g_mfx[f].api->destroy_instance(g_mfx[f].instance);
    }
    if (g_mfx[f].handle) dlclose(g_mfx[f].handle);
    memset(&g_mfx[f], 0, sizeof(g_mfx[f]));
}

/* dsp_path is a virtual /data/UserData path to the module's dsp.so */
static int mfx_load(int f, const char *dsp_path) {
    mfx_unload(f);
    if (!dsp_path || !dsp_path[0]) return 0;  /* empty = unload */

    char real[1024];
    schwung_remap(dsp_path, real, sizeof(real));
    void *h = schwung_dlopen_module(real, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "mfx: dlopen %s failed: %s\n", real, dlerror());
        return -1;
    }
    audio_fx_init_v2_fn init = (audio_fx_init_v2_fn)dlsym(h, AUDIO_FX_INIT_V2_SYMBOL);
    if (!init) {
        fprintf(stderr, "mfx: %s missing %s\n", real, AUDIO_FX_INIT_V2_SYMBOL);
        dlclose(h);
        return -1;
    }
    const audio_fx_api_v2_t *api = init(&g_host_api);
    if (!api) { dlclose(h); return -1; }

    /* module dir = parent of dsp.so; id = last dir component */
    char module_dir[512];
    strncpy(module_dir, dsp_path, sizeof(module_dir) - 1);
    module_dir[sizeof(module_dir) - 1] = '\0';
    char *slash = strrchr(module_dir, '/');
    if (slash) *slash = '\0';
    const char *id = strrchr(module_dir, '/');
    id = id ? id + 1 : module_dir;

    void *inst = api->create_instance(module_dir, NULL);
    if (!inst) { dlclose(h); return -1; }

    g_mfx[f].handle = h;
    g_mfx[f].api = api;
    g_mfx[f].instance = inst;
    g_mfx[f].bypassed = 0;
    strncpy(g_mfx[f].id, id, sizeof(g_mfx[f].id) - 1);
    strncpy(g_mfx[f].path, dsp_path, sizeof(g_mfx[f].path) - 1);
    return 0;
}

/* ============================================================================
 * Param protocol (mirrors shadow_chain_mgmt.c behavior)
 * ============================================================================ */

static void respond(shadow_param_t *p, const char *value, int err) {
    if (value) {
        strncpy(p->value, value, SHADOW_PARAM_VALUE_LEN - 1);
        p->value[SHADOW_PARAM_VALUE_LEN - 1] = '\0';
        p->result_len = (int32_t)strlen(p->value);
    } else {
        p->result_len = -1;
    }
    p->error = (uint8_t)err;
    p->response_id = p->request_id;
    __sync_synchronize();
    p->response_ready = 1;
    p->request_type = 0;
}

static int key_is_shim_special(const char *key) {
    return strncmp(key, "jack:", 5) == 0 ||
           strncmp(key, "overtake_dsp", 12) == 0 ||
           strcmp(key, "suspend_overtake") == 0 ||
           strcmp(key, "passthrough") == 0 ||
           strcmp(key, "resample_bridge") == 0 ||
           strcmp(key, "link_audio_routing") == 0 ||
           strcmp(key, "link_audio_publish") == 0 ||
           strcmp(key, "latency_comp_enabled") == 0 ||
           strcmp(key, "speaker_eq_mode") == 0 ||
           strcmp(key, "system_link_enabled") == 0 ||
           strcmp(key, "active_set") == 0;
}

static void handle_slot_param(shadow_param_t *p, int is_set) {
    int s = p->slot;
    const char *sub = p->key + 5;  /* past "slot:" */
    aslot_t *sl = &g_slots[s];
    char out[64];

    if (strcmp(sub, "volume") == 0) {
        if (is_set) {
            float v = strtof(p->value, NULL);
            if (v < 0) v = 0;
            if (v > 4.0f) v = 4.0f;
            sl->volume = v;
            ui_state_sync_slot(s);
            respond(p, "1", 0);
        } else {
            snprintf(out, sizeof(out), "%.2f", sl->volume);
            respond(p, out, 0);
        }
    } else if (strcmp(sub, "muted") == 0) {
        if (is_set) { sl->muted = atoi(p->value) ? 1 : 0; respond(p, "1", 0); }
        else { respond(p, sl->muted ? "1" : "0", 0); }
    } else if (strcmp(sub, "soloed") == 0) {
        if (is_set) { sl->soloed = atoi(p->value) ? 1 : 0; respond(p, "1", 0); }
        else { respond(p, sl->soloed ? "1" : "0", 0); }
    } else if (strcmp(sub, "forward_channel") == 0) {
        if (is_set) {
            int v = atoi(p->value);
            if (v < -2) v = -2;
            if (v > 15) v = 15;
            sl->forward = v;
            ui_state_sync_slot(s);
            respond(p, "1", 0);
        } else {
            snprintf(out, sizeof(out), "%d", sl->forward);
            respond(p, out, 0);
        }
    } else if (strcmp(sub, "receive_channel") == 0) {
        if (is_set) {
            int v = atoi(p->value);  /* UI encoding: 0 = All, 1-16 = channel */
            sl->channel = (v <= 0) ? -1 : (v - 1 > 15 ? 15 : v - 1);
            ui_state_sync_slot(s);
            respond(p, "1", 0);
        } else {
            snprintf(out, sizeof(out), "%d", sl->channel < 0 ? 0 : sl->channel + 1);
            respond(p, out, 0);
        }
    } else if (strcmp(sub, "transpose") == 0) {
        if (is_set) {
            int v = atoi(p->value);
            if (v < -12) v = -12;
            if (v > 12) v = 12;
            sl->transpose = v;
            respond(p, "1", 0);
        } else {
            snprintf(out, sizeof(out), "%d", sl->transpose);
            respond(p, out, 0);
        }
    } else {
        respond(p, NULL, 1);
    }
}

static alfo_t *lfo_for_key(const char *key, const char **rest) {
    /* key past "master_fx:": "lfo1:..." or "lfo2:..." */
    if (strncmp(key, "lfo1:", 5) == 0) { *rest = key + 5; return &g_lfos[0]; }
    if (strncmp(key, "lfo2:", 5) == 0) { *rest = key + 5; return &g_lfos[1]; }
    return NULL;
}

static void handle_lfo_param(shadow_param_t *p, alfo_t *l, const char *sub, int is_set) {
    char out[512];
    if (strcmp(sub, "config") == 0 && !is_set) {
        snprintf(out, sizeof(out),
                 "{\"enabled\":%d,\"shape\":%d,\"rate_hz\":%.4f,\"rate_div\":%d,"
                 "\"sync\":%d,\"depth\":%.4f,\"polarity\":%d,\"phase_offset\":%.4f,"
                 "\"target\":\"%s\",\"target_param\":\"%s\",\"division_table_version\":1}",
                 l->enabled, l->shape, l->rate_hz, l->rate_div, l->sync, l->depth,
                 l->polarity, l->phase_offset, l->target, l->target_param);
        respond(p, out, 0);
        return;
    }
    /* ":modulated" / ":base" introspection — no modulation engine here */
    if (strstr(sub, ":modulated")) { respond(p, "0", 0); return; }

    struct { const char *k; int *iv; float *fv; char *sv; size_t sn; } map[] = {
        {"enabled", &l->enabled, NULL, NULL, 0},
        {"shape", &l->shape, NULL, NULL, 0},
        {"rate_div", &l->rate_div, NULL, NULL, 0},
        {"sync", &l->sync, NULL, NULL, 0},
        {"polarity", &l->polarity, NULL, NULL, 0},
        {"rate_hz", NULL, &l->rate_hz, NULL, 0},
        {"depth", NULL, &l->depth, NULL, 0},
        {"phase_offset", NULL, &l->phase_offset, NULL, 0},
        {"target", NULL, NULL, l->target, sizeof(l->target)},
        {"target_param", NULL, NULL, l->target_param, sizeof(l->target_param)},
    };
    for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        if (strcmp(sub, map[i].k) != 0) continue;
        if (is_set) {
            if (map[i].iv) *map[i].iv = atoi(p->value);
            else if (map[i].fv) *map[i].fv = strtof(p->value, NULL);
            else { strncpy(map[i].sv, p->value, map[i].sn - 1); map[i].sv[map[i].sn - 1] = '\0'; }
            respond(p, "1", 0);
        } else {
            if (map[i].iv) snprintf(out, sizeof(out), "%d", *map[i].iv);
            else if (map[i].fv) snprintf(out, sizeof(out), "%.4f", *map[i].fv);
            else snprintf(out, sizeof(out), "%s", map[i].sv);
            respond(p, out, 0);
        }
        return;
    }
    respond(p, NULL, 1);
}

static void handle_mfx_param(shadow_param_t *p, int is_set) {
    const char *key = p->key + 10;  /* past "master_fx:" */
    const char *rest = NULL;
    alfo_t *l = lfo_for_key(key, &rest);
    if (l) { handle_lfo_param(p, l, rest, is_set); return; }

    if (strncmp(key, "fx", 2) != 0 || key[2] < '1' || key[2] > '4' || key[3] != ':') {
        respond(p, NULL, 8);
        return;
    }
    int f = key[2] - '1';
    const char *sub = key + 4;
    amfx_t *m = &g_mfx[f];

    if (strcmp(sub, "module") == 0) {
        if (is_set) {
            pthread_mutex_lock(&g_dsp);
            int rc = mfx_load(f, p->value);
            pthread_mutex_unlock(&g_dsp);
            respond(p, rc == 0 ? "1" : NULL, rc == 0 ? 0 : 7);
        } else {
            respond(p, m->path, 0);
        }
    } else if (strcmp(sub, "name") == 0) {
        respond(p, m->id, 0);
    } else if (strcmp(sub, "bypassed") == 0) {
        if (is_set) { m->bypassed = atoi(p->value) ? 1 : 0; respond(p, "1", 0); }
        else { respond(p, m->bypassed ? "1" : "0", 0); }
    } else if (m->api && m->instance) {
        if (is_set) {
            pthread_mutex_lock(&g_dsp);
            m->api->set_param(m->instance, sub, p->value);
            pthread_mutex_unlock(&g_dsp);
            respond(p, "1", 0);
        } else {
            char buf[SHADOW_PARAM_VALUE_LEN];
            pthread_mutex_lock(&g_dsp);
            int n = m->api->get_param(m->instance, sub, buf, sizeof(buf));
            pthread_mutex_unlock(&g_dsp);
            if (n >= 0) respond(p, buf, 0);
            else respond(p, NULL, 10);
        }
    } else {
        respond(p, NULL, 9);
    }
}

static void handle_chain_param(shadow_param_t *p, int is_set) {
    int s = p->slot;
    aslot_t *sl = &g_slots[s];
    if (!g_plugin || !sl->instance) { respond(p, NULL, 2); return; }

    if (is_set) {
        pthread_mutex_lock(&g_dsp);
        g_plugin->set_param(sl->instance, p->key, p->value);

        /* Activation side effects (shadow_chain_mgmt.c does the same) */
        if ((strcmp(p->key, "synth:module") == 0 ||
             strcmp(p->key, "fx1:module") == 0 || strcmp(p->key, "fx2:module") == 0 ||
             strcmp(p->key, "midi_fx1:module") == 0 || strcmp(p->key, "midi_fx2:module") == 0)) {
            if (p->value[0]) sl->active = 1;
            slot_probe_loaded(s);
        } else if (strcmp(p->key, "load_patch") == 0 || strcmp(p->key, "patch") == 0 ||
                   strcmp(p->key, "load_file") == 0) {
            slot_probe_loaded(s);
        }
        pthread_mutex_unlock(&g_dsp);
        respond(p, "1", 0);
    } else {
        /* Response goes straight into the SHM value buffer */
        pthread_mutex_lock(&g_dsp);
        int n = g_plugin->get_param(sl->instance, p->key, p->value, SHADOW_PARAM_VALUE_LEN);
        pthread_mutex_unlock(&g_dsp);
        if (n >= 0) {
            p->value[SHADOW_PARAM_VALUE_LEN - 1] = '\0';
            p->result_len = n;
            p->error = 0;
        } else {
            p->result_len = -1;
            p->error = 4;
        }
        p->response_id = p->request_id;
        __sync_synchronize();
        p->response_ready = 1;
        p->request_type = 0;
    }
}

/* Slot the JS is currently fetching knob mappings for — so the surface can
 * show the same per-knob labels the display does. */
static volatile int g_knob_slot = 0;

static void service_param_request(shadow_param_t *p) {
    int is_set = (p->request_type == 1);
    if (p->request_type != 1 && p->request_type != 2) { respond(p, NULL, 6); return; }
    if (p->slot >= SHADOW_CHAIN_INSTANCES) { respond(p, NULL, 1); return; }
    p->key[SHADOW_PARAM_KEY_LEN - 1] = '\0';
    if (strncmp(p->key, "knob_", 5) == 0) g_knob_slot = p->slot;

    if (strncmp(p->key, "slot:", 5) == 0) handle_slot_param(p, is_set);
    else if (strncmp(p->key, "master_fx:", 10) == 0) handle_mfx_param(p, is_set);
    else if (key_is_shim_special(p->key)) respond(p, NULL, 13);
    else handle_chain_param(p, is_set);
}

/* ============================================================================
 * Patch requests (control->ui_request_id) + MIDI-to-DSP drain
 * ============================================================================ */

static void check_patch_request(shadow_control_t *ctl) {
    static uint32_t last_id = 0;
    if (ctl->ui_request_id == last_id) return;
    last_id = ctl->ui_request_id;

    int s = ctl->ui_slot;
    if (s < 0 || s >= SHADOW_CHAIN_INSTANCES || !g_plugin || !g_slots[s].instance) return;

    char idx[16];
    if (ctl->ui_patch_index == SHADOW_PATCH_INDEX_NONE) {
        strcpy(idx, "-1");  /* chain unloads everything on negative index */
    } else {
        snprintf(idx, sizeof(idx), "%u", ctl->ui_patch_index);
    }
    pthread_mutex_lock(&g_dsp);
    g_plugin->set_param(g_slots[s].instance, "load_patch", idx);
    g_slots[s].active = (ctl->ui_patch_index != SHADOW_PATCH_INDEX_NONE);
    slot_probe_loaded(s);
    pthread_mutex_unlock(&g_dsp);
}

static void dispatch_to_slots(uint8_t status, uint8_t d1, uint8_t d2) {
    uint8_t type = status & 0xF0;
    int ch = status & 0x0F;
    if (type < 0x80 || type == 0xF0) return;

    for (int s = 0; s < SHADOW_CHAIN_INSTANCES; s++) {
        aslot_t *sl = &g_slots[s];
        if (!sl->instance || !sl->active) continue;
        if (sl->channel != -1 && sl->channel != ch) continue;

        uint8_t out_ch = (uint8_t)ch;
        if (sl->forward >= 0) out_ch = (uint8_t)sl->forward;
        else if (sl->forward == -1 && sl->channel >= 0) out_ch = (uint8_t)sl->channel;
        /* -2 (THRU) keeps the original channel */

        uint8_t nd1 = d1;
        if ((type == 0x90 || type == 0x80) && sl->transpose != 0) {
            int t = d1 + sl->transpose;
            if (t < 0 || t > 127) continue;
            nd1 = (uint8_t)t;
        }
        uint8_t msg[3] = {(uint8_t)(type | out_ch), nd1, d2};
        g_plugin->on_midi(sl->instance, msg, 3, MOVE_MIDI_SOURCE_EXTERNAL);
    }
}

static void drain_midi_dsp(shadow_midi_dsp_t *ring) {
    static uint8_t last_ready = 0;
    if (!ring || ring->ready == last_ready) return;
    last_ready = ring->ready;

    int len = ring->write_idx;
    if (len > SHADOW_MIDI_DSP_BUFFER_SIZE) len = SHADOW_MIDI_DSP_BUFFER_SIZE;
    uint8_t buf[SHADOW_MIDI_DSP_BUFFER_SIZE];
    if (len > 0) memcpy(buf, ring->buffer, (size_t)len);
    __sync_synchronize();
    ring->write_idx = 0;
    memset(ring->buffer, 0, SHADOW_MIDI_DSP_BUFFER_SIZE);

    pthread_mutex_lock(&g_dsp);
    for (int i = 0; i + 4 <= len; i += 4) {
        dispatch_to_slots(buf[i], buf[i + 1], buf[i + 2]);
    }
    pthread_mutex_unlock(&g_dsp);
}

void schwung_audio_play_note(uint8_t status, uint8_t d1, uint8_t d2) {
    if (!g_running || !g_plugin) return;
    shadow_control_t *ctl = schwung_shm_control();
    if (!ctl || ctl->pad_block) return;
    int s = ctl->selected_slot;
    if (s < 0 || s >= SHADOW_CHAIN_INSTANCES) s = 0;
    aslot_t *sl = &g_slots[s];
    if (!sl->instance || !sl->active) return;

    uint8_t ch = (uint8_t)(sl->channel >= 0 ? sl->channel : 0);
    if (sl->forward >= 0) ch = (uint8_t)sl->forward;
    uint8_t msg[3] = {(uint8_t)((status & 0xF0) | ch), d1, d2};
    pthread_mutex_lock(&g_dsp);
    g_plugin->on_midi(sl->instance, msg, 3, MOVE_MIDI_SOURCE_INTERNAL);
    pthread_mutex_unlock(&g_dsp);
}

static void *control_thread(void *arg) {
    (void)arg;
    shadow_param_t *param = schwung_shm_param();
    shadow_control_t *ctl = schwung_shm_control();
    shadow_midi_dsp_t *mdsp = schwung_shm_midi_dsp();

    while (g_running) {
        if (param && param->request_type != 0) service_param_request(param);
        if (ctl) check_patch_request(ctl);
        drain_midi_dsp(mdsp);
        usleep(500);
    }
    return NULL;
}

/* ============================================================================
 * Audio render
 * ============================================================================ */

/* Small prebuffer ring decouples the CoreAudio callback from the DSP mutex:
 * a producer thread renders ahead (may block briefly while params load), the
 * callback reads lock-free. RING_BLOCKS * 128 frames ≈ 23 ms extra latency. */
#define RING_BLOCKS 8
static int16_t g_ring[RING_BLOCKS][FRAMES_PER_BLOCK * 2];
static volatile uint32_t g_ring_w = 0, g_ring_r = 0;  /* block counters */
static int g_block_pos = FRAMES_PER_BLOCK;  /* frames consumed within the current read block */
static float g_last_peak = 0;
static pthread_t g_render_thread;

static void produce_block(int16_t *out) {
    int any_solo = 0;
    for (int s = 0; s < SHADOW_CHAIN_INSTANCES; s++) any_solo |= g_slots[s].soloed;

    int32_t acc[FRAMES_PER_BLOCK * 2] = {0};
    int16_t tmp[FRAMES_PER_BLOCK * 2];
    pthread_mutex_lock(&g_dsp);
    for (int s = 0; s < SHADOW_CHAIN_INSTANCES; s++) {
        aslot_t *sl = &g_slots[s];
        if (!sl->instance || !sl->active || sl->muted) continue;
        if (any_solo && !sl->soloed) continue;
        g_plugin->render_block(sl->instance, tmp, FRAMES_PER_BLOCK);
        float gain = sl->volume;
        for (int i = 0; i < FRAMES_PER_BLOCK * 2; i++) {
            acc[i] += (int32_t)(tmp[i] * gain);
        }
    }
    for (int i = 0; i < FRAMES_PER_BLOCK * 2; i++) {
        int32_t v = acc[i];
        out[i] = (int16_t)(v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
    }
    for (int f = 0; f < 4; f++) {
        if (g_mfx[f].api && g_mfx[f].instance && !g_mfx[f].bypassed) {
            g_mfx[f].api->process_block(g_mfx[f].instance, out, FRAMES_PER_BLOCK);
        }
    }
    pthread_mutex_unlock(&g_dsp);

    float peak = 0;
    for (int i = 0; i < FRAMES_PER_BLOCK * 2; i++) {
        float a = out[i] < 0 ? -out[i] : out[i];
        if (a > peak) peak = a;
    }
    g_last_peak = peak / 32768.0f;
    if (g_overlay) g_overlay->sampler_vu_peak = (int16_t)peak;
}

static void *render_thread(void *arg) {
    (void)arg;
    /* Audio production must not be starved by UI/main-thread work on device —
     * a normal-priority producer underruns the ring under real-time pressure,
     * which sounds like shredded/interlaced audio. */
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    while (g_running) {
        if (g_ring_w - g_ring_r < RING_BLOCKS) {
            produce_block(g_ring[g_ring_w % RING_BLOCKS]);
            __sync_synchronize();
            g_ring_w++;
        } else {
            usleep(500);
        }
    }
    return NULL;
}

static OSStatus render_cb(void *refCon, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts, UInt32 bus, UInt32 nframes,
                          AudioBufferList *io) {
    (void)refCon; (void)flags; (void)ts; (void)bus;
    /* RemoteIO on a real device hands back non-interleaved (planar) L/R buffers
     * even when we request interleaved — macOS/sim give one interleaved buffer.
     * Writing interleaved samples into a planar buffer is the "shredded, channels
     * interfering" artifact, so branch on the actual layout we're handed. */
    static int logged = 0;
    if (!logged) {
        logged = 1;
        fprintf(stderr, "engine: render_cb nframes=%u mNumberBuffers=%u "
                "buf0.mNumberChannels=%u buf0.mDataByteSize=%u%s\n",
                (unsigned)nframes, (unsigned)io->mNumberBuffers,
                (unsigned)io->mBuffers[0].mNumberChannels,
                (unsigned)io->mBuffers[0].mDataByteSize,
                io->mNumberBuffers >= 2 ? " [PLANAR]" : " [INTERLEAVED]");
    }
    float *L = (float *)io->mBuffers[0].mData;
    float *R = (io->mNumberBuffers >= 2) ? (float *)io->mBuffers[1].mData : NULL;
    static uint64_t g_underruns = 0, g_total = 0, g_last_report = 0;
    for (UInt32 i = 0; i < nframes; i++) {
        float l = 0, r = 0;
        g_total++;
        if (g_block_pos >= FRAMES_PER_BLOCK) {
            if (g_ring_w == g_ring_r) {  /* underrun: emit silence this frame */
                g_underruns++;
                if (R) { L[i] = 0; R[i] = 0; } else { L[i * 2] = 0; L[i * 2 + 1] = 0; }
                continue;
            }
            g_block_pos = 0;  /* begin consuming block at g_ring_r */
        }
        const int16_t *blk = g_ring[g_ring_r % RING_BLOCKS];
        l = blk[g_block_pos * 2] / 32768.0f;
        r = blk[g_block_pos * 2 + 1] / 32768.0f;
        if (R) { L[i] = l; R[i] = r; } else { L[i * 2] = l; L[i * 2 + 1] = r; }
        g_block_pos++;
        if (g_block_pos >= FRAMES_PER_BLOCK) g_ring_r++;  /* release consumed block */
    }
    /* Flag underruns ~once/sec only when they actually occur (quiet otherwise). */
    if (g_total - g_last_report >= 48000) {
        if (g_underruns > 0)
            fprintf(stderr, "engine: audio underruns %llu / %llu frames (%.2f%%)\n",
                    (unsigned long long)g_underruns, (unsigned long long)g_total,
                    100.0 * g_underruns / (double)g_total);
        g_last_report = g_total;
    }
    return noErr;
}

static int start_audio_unit(void) {
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
#if TARGET_OS_IPHONE
        .componentSubType = kAudioUnitSubType_RemoteIO,
#else
        .componentSubType = kAudioUnitSubType_DefaultOutput,
#endif
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) return -1;
    if (AudioComponentInstanceNew(comp, &g_au) != noErr) return -1;

    AudioStreamBasicDescription fmt = {
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mFramesPerPacket = 1,
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 32,
        .mBytesPerFrame = 8,
        .mBytesPerPacket = 8,
    };
    OSStatus st = AudioUnitSetProperty(g_au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (st != noErr) {
        /* Device rejected interleaved — fall back to non-interleaved (planar);
         * render_cb handles both layouts. */
        fprintf(stderr, "engine: interleaved format rejected (%d), trying planar\n", (int)st);
        fmt.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
        fmt.mBytesPerFrame = 4;
        fmt.mBytesPerPacket = 4;
        st = AudioUnitSetProperty(g_au, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
        if (st != noErr) { fprintf(stderr, "engine: planar also rejected (%d)\n", (int)st); return -1; }
    }
    AURenderCallbackStruct cb = {.inputProc = render_cb};
    if (AudioUnitSetProperty(g_au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                             0, &cb, sizeof(cb)) != noErr) return -1;
    if (AudioUnitInitialize(g_au) != noErr) return -1;

    /* Log the format the unit actually negotiated. */
    AudioStreamBasicDescription got = {0};
    UInt32 sz = sizeof(got);
    if (AudioUnitGetProperty(g_au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                             0, &got, &sz) == noErr) {
        fprintf(stderr, "engine: AU format sr=%.0f ch=%u bits=%u bytesPerFrame=%u flags=0x%x%s\n",
                got.mSampleRate, (unsigned)got.mChannelsPerFrame, (unsigned)got.mBitsPerChannel,
                (unsigned)got.mBytesPerFrame, (unsigned)got.mFormatFlags,
                (got.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? " [NONINTERLEAVED]" : " [INTERLEAVED]");
    }
    if (AudioOutputUnitStart(g_au) != noErr) return -1;
    return 0;
}

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

static void boot_restore_slots(void) {
    for (int s = 0; s < SHADOW_CHAIN_INSTANCES; s++) {
        char vpath[256], real[1024];
        snprintf(vpath, sizeof(vpath), SLOT_STATE_FMT, s);
        schwung_remap(vpath, real, sizeof(real));
        struct stat st;
        if (stat(real, &st) == 0 && st.st_size > 10) {
            pthread_mutex_lock(&g_dsp);
            g_plugin->set_param(g_slots[s].instance, "load_file", vpath);
            slot_probe_loaded(s);
            pthread_mutex_unlock(&g_dsp);
            fprintf(stderr, "engine: slot %d restored from autosave (active=%d)\n",
                    s, g_slots[s].active);
        }
    }
}

int schwung_audio_engine_start(void) {
    char real[1024];
    schwung_remap(CHAIN_DSP_PATH, real, sizeof(real));
    g_chain_handle = schwung_dlopen_module(real, RTLD_NOW | RTLD_LOCAL);
    if (!g_chain_handle) {
        fprintf(stderr, "engine: no chain dsp at %s (%s)\n", real, dlerror());
        return -1;
    }
    move_plugin_init_v2_fn init =
        (move_plugin_init_v2_fn)dlsym(g_chain_handle, MOVE_PLUGIN_INIT_V2_SYMBOL);
    if (!init) {
        fprintf(stderr, "engine: chain dsp missing %s\n", MOVE_PLUGIN_INIT_V2_SYMBOL);
        return -1;
    }
    init_host_api();
    g_overlay = schwung_shm_overlay();
    g_plugin = init(&g_host_api);
    if (!g_plugin || !g_plugin->create_instance || !g_plugin->render_block) {
        fprintf(stderr, "engine: chain init failed\n");
        return -1;
    }

    for (int s = 0; s < SHADOW_CHAIN_INSTANCES; s++) {
        g_slots[s].instance = g_plugin->create_instance(CHAIN_MODULE_DIR, NULL);
        g_slots[s].channel = s;       /* slot N receives channel N+1 (UI encoding) */
        g_slots[s].forward = -1;
        g_slots[s].volume = 1.0f;
        if (!g_slots[s].instance) {
            fprintf(stderr, "engine: create_instance failed for slot %d\n", s);
            return -1;
        }
        ui_state_sync_slot(s);
    }

    boot_restore_slots();

    g_running = 1;
    if (pthread_create(&g_ctl_thread, NULL, control_thread, NULL) != 0) return -1;
    if (pthread_create(&g_render_thread, NULL, render_thread, NULL) != 0) return -1;
    if (start_audio_unit() != 0) {
        fprintf(stderr, "engine: audio unit failed to start (params still live)\n");
    }
    fprintf(stderr, "engine: chain DSP live, 4 slots ready\n");
    return 0;
}

void schwung_audio_engine_stop(void) {
    g_running = 0;
    if (g_au) {
        AudioOutputUnitStop(g_au);
        AudioUnitUninitialize(g_au);
        AudioComponentInstanceDispose(g_au);
        g_au = NULL;
    }
}

float schwung_audio_peak(void) {
    return g_last_peak;
}

int schwung_selected_slot(void) {
    shadow_control_t *ctl = schwung_shm_control();
    return ctl ? ctl->selected_slot : 0;
}

int schwung_slot_active(int slot) {
    if (slot < 0 || slot >= SHADOW_CHAIN_INSTANCES) return 0;
    return g_running ? g_slots[slot].active : 0;
}

/* Live name+value the chain has mapped to knob `k` (0-7), for the slot the JS
 * is currently showing. Empty name → unmapped. Returns 1 if a name was found. */
int schwung_knob_label(int k, char *name, int nlen, char *value, int vlen) {
    if (name && nlen) name[0] = 0;
    if (value && vlen) value[0] = 0;
    if (!g_running || !g_plugin || !g_plugin->get_param || k < 0 || k > 7) return 0;
    int s = g_knob_slot;
    if (s < 0 || s >= SHADOW_CHAIN_INSTANCES || !g_slots[s].instance) return 0;
    char key[24];
    pthread_mutex_lock(&g_dsp);
    snprintf(key, sizeof(key), "knob_%d_name", k + 1);
    int n = g_plugin->get_param(g_slots[s].instance, key, name, nlen);
    if (n > 0 && value && vlen) {
        snprintf(key, sizeof(key), "knob_%d_value", k + 1);
        g_plugin->get_param(g_slots[s].instance, key, value, vlen);
    }
    pthread_mutex_unlock(&g_dsp);
    if (n <= 0) { if (name && nlen) name[0] = 0; return 0; }
    name[nlen - 1] = 0;
    if (value && vlen) value[vlen - 1] = 0;
    return 1;
}
