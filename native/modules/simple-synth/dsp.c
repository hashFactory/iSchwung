/* simple-synth: a small polyphonic synth proving iSchwung's chain pipeline.
 * Implements schwung plugin API v2 (see git-schwung/src/host/plugin_api_v1.h).
 * 16-voice saw/square/sine, one-pole lowpass, AR envelope. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "host/plugin_api_v1.h"

#define VOICES 16
#define SR 44100.0f

typedef struct {
    int note;          /* -1 = free */
    float phase, freq, vel;
    float env;         /* envelope level */
    int gate;
} voice_t;

typedef struct {
    voice_t v[VOICES];
    int wave;          /* 0 saw, 1 square, 2 sine */
    float cutoff;      /* 0..1 */
    float attack_ms, release_ms, gain;
    float lp_l, lp_r;
    unsigned rr;       /* round-robin steal cursor */
} synth_t;

static const host_api_v1_t *g_host;

static void s_defaults(synth_t *s) {
    for (int i = 0; i < VOICES; i++) s->v[i].note = -1;
    s->wave = 0;
    s->cutoff = 0.6f;
    s->attack_ms = 3.0f;
    s->release_ms = 220.0f;
    s->gain = 0.8f;
}

static void *s_create(const char *module_dir, const char *json_defaults) {
    (void)module_dir; (void)json_defaults;
    synth_t *s = calloc(1, sizeof(synth_t));
    if (s) s_defaults(s);
    return s;
}

static void s_destroy(void *inst) { free(inst); }

static void s_on_midi(void *inst, const uint8_t *msg, int len, int source) {
    (void)source;
    synth_t *s = inst;
    if (!s || len < 3) return;
    uint8_t type = msg[0] & 0xF0;
    if (type == 0x90 && msg[2] > 0) {
        int slot = -1;
        for (int i = 0; i < VOICES; i++) {
            if (s->v[i].note < 0) { slot = i; break; }
        }
        if (slot < 0) slot = (int)(s->rr++ % VOICES);
        voice_t *v = &s->v[slot];
        v->note = msg[1];
        v->freq = 440.0f * powf(2.0f, (msg[1] - 69) / 12.0f);
        v->vel = msg[2] / 127.0f;
        v->phase = 0;
        v->gate = 1;
    } else if (type == 0x80 || (type == 0x90 && msg[2] == 0)) {
        for (int i = 0; i < VOICES; i++) {
            if (s->v[i].note == msg[1] && s->v[i].gate) s->v[i].gate = 0;
        }
    } else if (type == 0xB0 && msg[1] == 123) {  /* all notes off */
        for (int i = 0; i < VOICES; i++) s->v[i].gate = 0;
    }
}

static void s_render(void *inst, int16_t *out, int frames) {
    synth_t *s = inst;
    if (!s) { memset(out, 0, (size_t)frames * 4); return; }

    float atk = 1.0f / (s->attack_ms * 0.001f * SR + 1.0f);
    float rel = 1.0f / (s->release_ms * 0.001f * SR + 1.0f);
    /* perceptual-ish cutoff curve: 80 Hz .. ~12 kHz */
    float fc = 80.0f * powf(150.0f, s->cutoff);
    float a = 1.0f - expf(-2.0f * (float)M_PI * fc / SR);

    for (int i = 0; i < frames; i++) {
        float mix = 0;
        for (int k = 0; k < VOICES; k++) {
            voice_t *v = &s->v[k];
            if (v->note < 0) continue;
            v->env += v->gate ? (1.0f - v->env) * atk : -v->env * rel;
            if (!v->gate && v->env < 0.0005f) { v->note = -1; continue; }
            v->phase += v->freq / SR;
            if (v->phase >= 1.0f) v->phase -= 1.0f;
            float smp;
            if (s->wave == 0) smp = 2.0f * v->phase - 1.0f;
            else if (s->wave == 1) smp = v->phase < 0.5f ? 1.0f : -1.0f;
            else smp = sinf(2.0f * (float)M_PI * v->phase);
            mix += smp * v->env * v->vel;
        }
        mix *= s->gain * 0.25f;
        s->lp_l += (mix - s->lp_l) * a;
        float o = s->lp_l;
        if (o > 1.0f) o = 1.0f;
        if (o < -1.0f) o = -1.0f;
        int16_t q = (int16_t)(o * 32000.0f);
        out[i * 2] = q;
        out[i * 2 + 1] = q;
    }
}

static const char *CHAIN_PARAMS =
    "[{\"key\":\"wave\",\"name\":\"Wave\",\"type\":\"enum\",\"options\":[\"Saw\",\"Square\",\"Sine\"]},"
    "{\"key\":\"cutoff\",\"name\":\"Cutoff\",\"type\":\"float\",\"min\":0,\"max\":1,\"step\":0.01,\"default\":0.6},"
    "{\"key\":\"attack\",\"name\":\"Attack\",\"type\":\"float\",\"min\":1,\"max\":500,\"step\":1,\"unit\":\"ms\",\"default\":3},"
    "{\"key\":\"release\",\"name\":\"Release\",\"type\":\"float\",\"min\":10,\"max\":2000,\"step\":10,\"unit\":\"ms\",\"default\":220},"
    "{\"key\":\"gain\",\"name\":\"Gain\",\"type\":\"float\",\"min\":0,\"max\":1,\"step\":0.01,\"default\":0.8}]";

static const char *UI_HIERARCHY =
    "{\"modes\":null,\"levels\":{\"root\":{\"label\":\"Simple\","
    "\"knobs\":[\"wave\",\"cutoff\",\"attack\",\"release\",\"gain\"],"
    "\"params\":[{\"key\":\"wave\",\"label\":\"Wave\"},{\"key\":\"cutoff\",\"label\":\"Cutoff\"},"
    "{\"key\":\"attack\",\"label\":\"Attack\"},{\"key\":\"release\",\"label\":\"Release\"},"
    "{\"key\":\"gain\",\"label\":\"Gain\"}]}}}";

static void s_set_param(void *inst, const char *key, const char *val) {
    synth_t *s = inst;
    if (!s || !key || !val) return;
    if (strcmp(key, "wave") == 0) {
        int w = atoi(val);
        s->wave = w < 0 ? 0 : (w > 2 ? 2 : w);
    } else if (strcmp(key, "cutoff") == 0) {
        float f = strtof(val, NULL);
        s->cutoff = f < 0 ? 0 : (f > 1 ? 1 : f);
    } else if (strcmp(key, "attack") == 0) {
        s->attack_ms = strtof(val, NULL);
    } else if (strcmp(key, "release") == 0) {
        s->release_ms = strtof(val, NULL);
    } else if (strcmp(key, "gain") == 0) {
        s->gain = strtof(val, NULL);
    } else if (strcmp(key, "state") == 0) {
        int w; float c, a, r, g;
        if (sscanf(val, "{\"wave\":%d,\"cutoff\":%f,\"attack\":%f,\"release\":%f,\"gain\":%f",
                   &w, &c, &a, &r, &g) == 5) {
            s->wave = w; s->cutoff = c; s->attack_ms = a; s->release_ms = r; s->gain = g;
        }
    }
}

static int s_get_param(void *inst, const char *key, char *buf, int buf_len) {
    synth_t *s = inst;
    if (!s || !key || !buf || buf_len < 1) return -1;
    if (strcmp(key, "chain_params") == 0) return snprintf(buf, (size_t)buf_len, "%s", CHAIN_PARAMS);
    if (strcmp(key, "ui_hierarchy") == 0) return snprintf(buf, (size_t)buf_len, "%s", UI_HIERARCHY);
    if (strcmp(key, "wave") == 0) return snprintf(buf, (size_t)buf_len, "%d", s->wave);
    if (strcmp(key, "cutoff") == 0) return snprintf(buf, (size_t)buf_len, "%.3f", s->cutoff);
    if (strcmp(key, "attack") == 0) return snprintf(buf, (size_t)buf_len, "%.1f", s->attack_ms);
    if (strcmp(key, "release") == 0) return snprintf(buf, (size_t)buf_len, "%.1f", s->release_ms);
    if (strcmp(key, "gain") == 0) return snprintf(buf, (size_t)buf_len, "%.3f", s->gain);
    if (strcmp(key, "state") == 0) {
        return snprintf(buf, (size_t)buf_len,
                        "{\"wave\":%d,\"cutoff\":%.3f,\"attack\":%.1f,\"release\":%.1f,\"gain\":%.3f}",
                        s->wave, s->cutoff, s->attack_ms, s->release_ms, s->gain);
    }
    return -1;
}

static int s_get_error(void *inst, char *buf, int buf_len) {
    (void)inst;
    if (buf && buf_len > 0) buf[0] = '\0';
    return 0;
}

static plugin_api_v2_t g_api = {
    .api_version = 2,
    .create_instance = s_create,
    .destroy_instance = s_destroy,
    .on_midi = s_on_midi,
    .set_param = s_set_param,
    .get_param = s_get_param,
    .get_error = s_get_error,
    .render_block = s_render,
};

plugin_api_v2_t *move_plugin_init_v2(const host_api_v1_t *host) {
    g_host = host;
    return &g_api;
}
