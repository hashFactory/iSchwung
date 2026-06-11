/* smoke_test.c - Headless boot test: start the engine, poke some MIDI at it,
 * dump the 128x64 framebuffer as ASCII. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include "../include/schwung_apple.h"
#include "../../git-schwung/src/host/shadow_constants.h"

static void *test_attach(const char *name, size_t size) {
    int fd = shm_open(name, O_RDWR, 0666);
    if (fd < 0) return NULL;
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return p == MAP_FAILED ? NULL : p;
}

static shadow_param_t *test_attach_param(void) {
    return test_attach(SHM_SHADOW_PARAM, SHADOW_PARAM_BUFFER_SIZE);
}

/* Mimic js_shadow_send_midi_to_dsp: linear buffer + ready++ */
static void test_send_dsp_note(uint8_t status, uint8_t d1, uint8_t d2) {
    static shadow_midi_dsp_t *ring = NULL;
    if (!ring) ring = test_attach(SHM_SHADOW_MIDI_DSP, sizeof(shadow_midi_dsp_t));
    if (!ring) return;
    int off = ring->write_idx;
    if (off + 4 <= SHADOW_MIDI_DSP_BUFFER_SIZE) {
        ring->buffer[off] = status;
        ring->buffer[off + 1] = d1;
        ring->buffer[off + 2] = d2;
        ring->buffer[off + 3] = 0;
        ring->write_idx = (uint8_t)(off + 4);
    }
    __sync_synchronize();
    ring->ready++;
}

static void dump_display(void) {
    const uint8_t *fb = schwung_display_buffer();
    if (!fb) { printf("(no display buffer)\n"); return; }
    /* Packed: band y8 (0..7) x column (0..127), bit n = row y8*8 + n */
    for (int y = 0; y < 64; y += 2) {  /* halve vertically for terminal aspect */
        for (int x = 0; x < 128; x++) {
            int on1 = (fb[(y / 8) * 128 + x] >> (y % 8)) & 1;
            int on2 = (fb[((y + 1) / 8) * 128 + x] >> ((y + 1) % 8)) & 1;
            putchar(on1 || on2 ? '#' : ' ');
        }
        putchar('\n');
    }
}

int main(int argc, char *argv[]) {
    const char *root = argc > 1 ? argv[1] : "/tmp/ischwung-data";
    char script[1024];
    snprintf(script, sizeof(script), "%s/schwung/shadow/shadow_ui.js", root);

    schwung_set_data_root(root);
    if (schwung_engine_start(script) != 0) {
        fprintf(stderr, "engine start failed\n");
        return 1;
    }

    sleep(3);
    printf("=== boot ===\n");
    dump_display();

    /* Turn the jog wheel a couple of clicks and re-dump */
    schwung_send_internal_midi(0xB0, 14, 1);
    usleep(100000);
    schwung_send_internal_midi(0xB0, 14, 1);
    sleep(1);
    printf("=== after jog x2 ===\n");
    dump_display();

    /* Drain LED traffic */
    uint8_t leds[512];
    int n = schwung_drain_midi_out(leds, sizeof(leds));
    printf("=== %d bytes of MIDI out ===\n", n);
    for (int i = 0; i < n && i < 64; i += 4) {
        printf("  [%02x %02x %02x %02x]\n", leds[i], leds[i+1], leds[i+2], leds[i+3]);
    }

    /* === Audio: load simple-synth into slot 1 and play a note === */
    shadow_param_t *p = test_attach_param();
    if (p) {
        strcpy(p->key, "synth:module");
        strcpy(p->value, "simple-synth");
        p->slot = 0;
        p->response_ready = 0;
        p->error = 0;
        p->request_id = 9001;
        p->request_type = 1;
        for (int i = 0; i < 500 && !(p->response_ready && p->response_id == 9001); i++) {
            usleep(2000);
        }
        printf("=== synth load: ready=%d err=%d ===\n", p->response_ready, p->error);

        test_send_dsp_note(0x90, 60, 110);
        usleep(400000);
        float peak = schwung_audio_peak();
        printf("=== audio peak after note: %.4f %s ===\n", peak,
               peak > 0.01f ? "(SOUND!)" : "(silence)");
        test_send_dsp_note(0x80, 60, 0);
    }

    schwung_engine_stop();
    usleep(300000);
    return 0;
}
