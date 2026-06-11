/* apple_internal.h - Cross-TU plumbing between the compat layer and the audio
 * engine. Not part of the Swift bridging surface. */

#ifndef APPLE_INTERNAL_H
#define APPLE_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include "host/shadow_constants.h"

/* SHM segment accessors (owned by apple_compat.c) */
shadow_param_t *schwung_shm_param(void);
shadow_control_t *schwung_shm_control(void);
shadow_ui_state_t *schwung_shm_ui_state(void);
shadow_midi_dsp_t *schwung_shm_midi_dsp(void);
shadow_overlay_state_t *schwung_shm_overlay(void);

/* Virtual → real path translation (returns buf or the input unchanged). */
const char *schwung_remap(const char *path, char *buf, size_t buf_len);

/* dlopen with module → embedded-bundle-dylib redirect (no-op unless Swift
 * registered a dylib dir; required for on-device iOS library validation). */
void *schwung_dlopen_module(const char *path, int mode);

/* Audio engine (apple_audio_engine.c). start returns 0 if the chain DSP was
 * found and the engine is live; nonzero → caller falls back to the param stub. */
int schwung_audio_engine_start(void);
void schwung_audio_engine_stop(void);

/* Surface note events (pads) → the selected slot's chain. On-device this path
 * runs through Move firmware, which doesn't exist here. No-op when engine off. */
void schwung_audio_play_note(uint8_t status, uint8_t d1, uint8_t d2);

#endif /* APPLE_INTERNAL_H */
