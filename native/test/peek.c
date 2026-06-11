/* peek.c - Attach to the running app's SHM segments: dump the display as
 * ASCII, or inject internal MIDI (drive the UI from the CLI). */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include "../../git-schwung/src/host/shadow_constants.h"

/* PEEK_SHM_DIR: attach to the iOS app's file-backed segments (<dir>/<name>)
 * instead of real POSIX SHM — works against the simulator's data root. */
static void *attach(const char *name, size_t size) {
    int fd;
    const char *dir = getenv("PEEK_SHM_DIR");
    if (dir) {
        char path[1024];
        snprintf(path, sizeof(path), "%s%s", dir, name);
        fd = open(path, O_RDWR);
    } else {
        fd = shm_open(name, O_RDWR, 0666);
    }
    if (fd < 0) { fprintf(stderr, "no segment %s (app running?)\n", name); exit(1); }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    return p;
}

static void send_midi(uint8_t *ring, shadow_control_t *ctl,
                      uint8_t status, uint8_t d1, uint8_t d2) {
    uint8_t head = (uint8_t)(status >> 4);
    for (int slot = 0; slot < MIDI_BUFFER_SIZE; slot += 4) {
        if (__atomic_load_n(&ring[slot], __ATOMIC_ACQUIRE) == 0) {
            ring[slot + 1] = status;
            ring[slot + 2] = d1;
            ring[slot + 3] = d2;
            __atomic_store_n(&ring[slot], head, __ATOMIC_RELEASE);
            ctl->midi_ready++;
            return;
        }
    }
}

int main(int argc, char *argv[]) {
    uint8_t *fb = attach(SHM_SHADOW_DISPLAY, DISPLAY_BUFFER_SIZE);
    shadow_control_t *ctl = attach(SHM_SHADOW_CONTROL, CONTROL_BUFFER_SIZE);
    uint8_t *ring = attach(SHM_SHADOW_UI_MIDI, MIDI_BUFFER_SIZE);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "dump") == 0) {
            for (int y = 0; y < 64; y += 2) {
                for (int x = 0; x < 128; x++) {
                    int a = (fb[(y / 8) * 128 + x] >> (y % 8)) & 1;
                    int b = (fb[((y + 1) / 8) * 128 + x] >> ((y + 1) % 8)) & 1;
                    putchar(a || b ? '#' : ' ');
                }
                putchar('\n');
            }
        } else if (strcmp(argv[i], "cc") == 0 && i + 2 < argc) {
            send_midi(ring, ctl, 0xB0, (uint8_t)atoi(argv[i + 1]), (uint8_t)atoi(argv[i + 2]));
            i += 2;
        } else if (strcmp(argv[i], "note") == 0 && i + 2 < argc) {
            int vel = atoi(argv[i + 2]);
            send_midi(ring, ctl, vel > 0 ? 0x90 : 0x80, (uint8_t)atoi(argv[i + 1]), (uint8_t)vel);
            i += 2;
        } else if ((strcmp(argv[i], "set") == 0 && i + 3 < argc) ||
                   (strcmp(argv[i], "get") == 0 && i + 2 < argc)) {
            int is_set = argv[i][0] == 's';
            shadow_param_t *p = attach(SHM_SHADOW_PARAM, SHADOW_PARAM_BUFFER_SIZE);
            while (p->request_type != 0) usleep(1000);
            p->slot = (uint8_t)atoi(argv[i + 1]);
            strncpy(p->key, argv[i + 2], sizeof(p->key) - 1);
            memset(p->value, 0, 256);
            if (is_set) strncpy(p->value, argv[i + 3], sizeof(p->value) - 1);
            p->response_ready = 0;
            p->error = 0;
            p->request_id = (uint32_t)getpid() * 100 + (uint32_t)i;
            p->request_type = is_set ? 1 : 2;
            for (int w = 0; w < 1000 && !(p->response_ready && p->response_id == p->request_id); w++) {
                usleep(1000);
            }
            printf("%s %s -> err=%d len=%d value=%.200s\n", is_set ? "set" : "get",
                   argv[i + 2], p->error, p->result_len, p->value);
            i += is_set ? 3 : 2;
        } else if (strcmp(argv[i], "dspnote") == 0 && i + 2 < argc) {
            /* raw 3-byte MIDI into the midi-dsp ring (what JS preview does) */
            shadow_midi_dsp_t *ring = attach(SHM_SHADOW_MIDI_DSP, sizeof(shadow_midi_dsp_t));
            int vel = atoi(argv[i + 2]);
            int off = ring->write_idx;
            if (off + 4 <= SHADOW_MIDI_DSP_BUFFER_SIZE) {
                ring->buffer[off] = vel > 0 ? 0x90 : 0x80;
                ring->buffer[off + 1] = (uint8_t)atoi(argv[i + 1]);
                ring->buffer[off + 2] = (uint8_t)vel;
                ring->buffer[off + 3] = 0;
                ring->write_idx = (uint8_t)(off + 4);
            }
            __sync_synchronize();
            ring->ready++;
            i += 2;
        } else if (strcmp(argv[i], "flags") == 0 && i + 1 < argc) {
            ctl->ui_flags |= (uint8_t)strtol(argv[i + 1], NULL, 0);
            i += 1;
        } else if (strcmp(argv[i], "vu") == 0) {
            shadow_overlay_state_t *ov = attach(SHM_SHADOW_OVERLAY, SHADOW_OVERLAY_BUFFER_SIZE);
            printf("vu peak: %d (%.3f)\n", ov->sampler_vu_peak, ov->sampler_vu_peak / 32768.0);
        } else if (strcmp(argv[i], "sleep") == 0 && i + 1 < argc) {
            usleep((useconds_t)(atof(argv[i + 1]) * 1e6));
            i += 1;
        } else {
            fprintf(stderr, "usage: peek [dump] [cc N V] [note N VEL] [sleep S] ...\n");
            return 2;
        }
    }
    return 0;
}
