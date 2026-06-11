/* schwung_apple.h - Public API of the Apple compat layer (also the Swift bridging surface).
 * Hosts schwung's shadow_ui.c unmodified inside a macOS app: SHM segments are
 * created locally, /data/UserData paths are remapped to a per-user data root. */

#ifndef SCHWUNG_APPLE_H
#define SCHWUNG_APPLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must be called before schwung_engine_start. data_root replaces "/data/UserData". */
void schwung_set_data_root(const char *data_root);

/* On-device iOS: dir holding the embedded, signed module dylibs
 * (schwung_<category>_<id>.dylib); dlopen of modules/.../dsp.so redirects there. */
void schwung_set_dylib_dir(const char *dir);

/* Creates + zero-inits all SHM segments, seeds control/ui state, starts the
 * param stub responder thread and the shadow_ui main loop thread.
 * script_path: absolute (real) path to shadow_ui.js. Returns 0 on success. */
int schwung_engine_start(const char *script_path);

/* Ask the shadow_ui loop to exit (saves JS state first). */
void schwung_engine_stop(void);

/* 128x64 1-bit packed display buffer (1024 bytes), live-updated by the JS UI.
 * Layout: for each 8-pixel row band y8 (0..7), 128 column bytes; bit n = row y8*8+n. */
const uint8_t *schwung_display_buffer(void);

/* Monotonic counter bumped every display flush; cheap dirty check for the UI. */
uint32_t schwung_display_generation(void);

/* Send one internal (cable 0) MIDI event from the virtual surface. */
void schwung_send_internal_midi(uint8_t status, uint8_t d1, uint8_t d2);

/* Mirror of physical shift state (the shim normally maintains this). */
void schwung_set_shift_held(int held);

/* Set SHADOW_UI_FLAG_* bits (e.g. jump-to-slot on open). */
void schwung_set_ui_flags(uint8_t mask);

/* Drain MIDI sent by the UI (LED updates etc). Copies up to max_len bytes of
 * 4-byte USB-MIDI packets [cin|cable, status, d1, d2] into out; returns bytes copied. */
int schwung_drain_midi_out(uint8_t *out, int max_len);

/* Peak (0..1) of the last rendered audio block; 0 when the engine is absent. */
float schwung_audio_peak(void);

/* Slot state for surface LED defaults (Move firmware drives LEDs on-device). */
int schwung_selected_slot(void);
int schwung_slot_active(int slot);

/* Transport: the play button toggles a MIDI clock that drives sequencer MIDI FX
 * (euclidrum, clock-synced arps). There is no Move sequencer here, so this is
 * the only clock source. */
void schwung_set_transport(int playing);
int schwung_transport_playing(void);

/* Live label the chain has mapped to knob k (0-7): name + formatted value, for
 * the slot currently shown. *norm gets the value normalized to [0,1] over its
 * range, or -1 if unknown. Returns 1 if mapped (name non-empty), 0 otherwise. */
int schwung_knob_label(int k, char *name, int nlen, char *value, int vlen, float *norm);

/* Generic get_param against a chain slot (slot < 0 → the slot the JS is showing).
 * Used to read synth:ui_hierarchy / synth:chain_params / synth:<key> so Swift can
 * label the synth's default knobs when no performance macro is mapped. */
int schwung_chain_param(int slot, const char *key, char *buf, int len);

/* Set a chain param to an absolute value (slot < 0 → the shown slot), so a knob
 * can map drag distance → value uniformly instead of sending relative ticks. */
int schwung_set_chain_param(int slot, const char *key, const char *value);

/* Most recent `max` mono output samples (~[-1,1], chronological) for the
 * on-screen spectrogram. Returns the count copied. */
int schwung_audio_capture(float *out, int max);

#ifdef __cplusplus
}
#endif

#endif /* SCHWUNG_APPLE_H */
