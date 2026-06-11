# iSchwung Feasibility Study — Porting Schwung's Shadow UI to macOS / iOS / iPadOS

*Research date: 2026-06-10, against `git-schwung` @ 49c3a0f.*

## Verdict

**Feasible, and the architecture cooperates.** Schwung's shadow UI was built as a separate
process (`shadow_ui` binary) that talks to the audio side exclusively through 12 shared-memory
structs and a small plugin API — there is no direct hardware access in the UI layer at all.
The entire UI logic (~18k lines of JS) is pure logic against ~84 C bindings and is portable
as-is. The piece we replace is exactly the piece the user asked to replace: the LD_PRELOAD
shim (`schwung_shim.c`), which owns SPI, mixing, and Move-firmware entanglement.

Estimated effort: **macOS proof-of-concept in ~2–3 weeks of focused work; iOS/iPadOS adds
~2–4 weeks** (sandbox, no fork/exec, plugin packaging). Modifications to the schwung repo can
plausibly be kept to: a path-root macro, a couple of `#ifdef __APPLE__` guards, and optional
stub headers — everything else lives in new files in iSchwung.

## How Schwung is shaped (what we learned)

```
On the Move:
  schwung_shim.so (LD_PRELOAD into Move firmware)      ← NOT ported
    owns /dev/ablspi0.0, mixes audio, renders 4 chain slots + master FX,
    services param requests, Link Audio, sampler/skipback
        ↕ 12 POSIX SHM segments (structs in src/host/shadow_constants.h)
  shadow_ui (separate binary, src/shadow/shadow_ui.c)  ← PORTED (mostly reusable)
    QuickJS + ~84 C→JS bindings + 60 Hz tick loop
    runs shadow_ui.js (16k lines) + 7 .mjs files + src/shared/*.mjs
```

Key verified facts:

- **`shadow_ui.js` is hand-maintained, not generated.** Build just copies it
  (`scripts/build.sh:666`). It imports QuickJS `std`/`os` plus `shared/*.mjs`. No bundler,
  no npm deps, no hardware assumptions. Portable byte-for-byte.
- **The UI↔audio contract is narrow and explicit**: the SHM structs in
  `src/host/shadow_constants.h` (control flags, slot state, a param get/set
  request/response box with 64-byte key / 64 KB value, MIDI rings in USB-MIDI 4-byte packet
  format, the 1024-byte display buffer, LED/midi-out ring).
- **`src/host/shadow_chain_mgmt.c` (2851 lines) is the reusable audio engine core.** It was
  already extracted from the shim, contains zero `shm`/`ioctl`/SPI references, and manages:
  the 4 chain slots, master FX slots, patch/param handling, boot init, autosave
  (`slot_N.json` / `master_fx_N.json`). It drives the chain plugin through
  `plugin_api_v2_t` + 4 chain extras (`chain_set_inject_audio`,
  `chain_set_external_fx_mode`, `chain_process_fx`, `chain_fx_requires_continuous`).
- **`src/modules/chain/dsp/chain_host.c` (9k lines) is portable C** — the full
  midi-fx → sound-generator → audio-fx pipeline, patch JSON load/save, LFOs, knob CC
  mapping. Depends only on libc/libm/pthread/dlfcn and the headers in `src/host/`. From
  `host_api_v1_t` it actually uses only: `log`, `get_bpm`, `get_clock_status`,
  `sample_rate`, `frames_per_block`, `slot_recv_channel` — all trivially stubbable.
- **Built-in DSP is plain C** (freeverb, arp, chord, velocity_scale, wav-player, linein) —
  compiles for Apple targets unchanged. **QuickJS 2025-04-26** builds on macOS/iOS with
  clang (drop `-lrt`).
- **Display**: 128×64 1-bit, packed to 1024 bytes by `js_display_pack()`
  (`src/host/js_display.c:149`). Drawing primitives + Tamzen BDF fonts (`fonts/tamzen/`)
  + stb_truetype already live in `js_display.c` (657 lines, portable).
- **Controls are fully enumerable from `src/shared/constants.mjs:503-630`**: 32 RGB pads
  (notes 68–99, 4×8), 16 steps (notes 16–31), tracks CC40–43 (reversed), 8 relative
  encoders CC71–78 (+capacitive touch notes 0–9), jog CC14/click CC3, volume CC79,
  function buttons (shift 49, menu 50, back 51, play 85, rec 86, mute 88, …), 128-entry
  RGB LED palette with hex values, white-LED brightness levels. Everything needed to draw
  and wire a faithful virtual Move is in the repo. (No device photos in-repo; visual
  reference comes from the real device.)

## Proposed architecture (single process)

The SHM segments exist *only because shadow_ui and the shim are different processes*. In
iSchwung, UI host and audio engine live in one app, so every segment becomes a plain
malloc'd struct — same types from `shadow_constants.h`, no IPC at all. The existing
acquire/release atomics in the MIDI rings carry over as the thread-safety mechanism
between the UI thread and audio thread.

```
iSchwung.app
├── SwiftUI layer (new)
│   ├── MoveSurfaceView — pads/steps/buttons/encoders/jog drawn from LED state;
│   │   touches/drags → USB-MIDI 4-byte packets → ui-midi ring
│   └── DisplayView — renders the 1024-byte framebuffer (Canvas/Metal, trivial)
├── UI host thread (reused C)
│   └── shadow_ui.c main loop + QuickJS + js_display.c, with open_shadow_shm()
│       swapped for local allocation; runs shadow_ui.js unmodified
└── Audio engine (new thin host, ~500–1000 lines C/Swift)
    ├── AVAudioEngine source node / AudioUnit callback @ 44.1 kHz, 128-frame blocks
    ├── shadow_chain_mgmt.c (reused) → 4× chain_host instances + 4 master FX slots
    ├── MIDI in: virtual surface ring + CoreMIDI (real controllers!) → dispatch by
    │   slot receive_channel
    ├── param request servicing (read shadow_param_t, call plugin get/set_param)
    └── LED/midi-out ring drain → Swift LED state (instead of SPI)
```

What the thin Apple audio backend must implement (replacing ~2k relevant lines of shim):

1. Render loop per block: for each active slot `render_block()` → `chain_process_fx()`
   → per-slot volume/mute/solo/fade → mix → master FX `process_block()` → master volume
   → output buffer. (The shim's idle-gating and deferred-FX split exist for the Move's
   900µs SPI budget; on Apple silicon we can run the simple synchronous path.)
2. `host_api_v1_t` stub: log → os_log/unified logger, bpm/clock → app transport (fixed
   120 or a tempo control), `slot_recv_channel` → slot table lookup.
3. Param servicing + autosave JSON read/write under an app-container root.
4. MIDI routing: surface + CoreMIDI → `on_midi()` per slot; chain forward-channel
   semantics can be kept or simplified.

Cleanly omitted (only exist because Move firmware runs alongside): Link Audio rebuild +
latency comp, master-volume estimation, speaker EQ, set pages, MIDI inject-to-Move,
cable-2 remap, D-Bus screen reader (later: AVSpeechSynthesizer), sampler/skipback
(later: reimplement against our own render buffer — the capture point is clean).

## Minimal-modification strategy for git-schwung

| Change | Size | Upstreamable? |
|---|---|---|
| Path root: `/data/UserData/schwung/...` is hardcoded across shadow_ui.c, chain_host.c, shadow_chain_mgmt.c. Introduce a `SCHWUNG_ROOT` compile-time prefix macro (or runtime getenv) | small, mechanical | yes — harmless upstream |
| `open_shadow_shm()`: allow a build flag where segments are locally allocated instead of `shm_open` (or simply link a replacement function from iSchwung — zero repo change on macOS since `shm_open` actually works there) | tiny | yes |
| `#include <malloc.h>` in chain_host.c → `<stdlib.h>` guard | 1 line | yes |
| `sched_setscheduler` guards (`#ifdef __APPLE__` no-op) | few lines | yes |
| fork/exec helpers (`host_http_download` via curl, `host_extract_tar`, `host_ensure_dir`) — fine on macOS as-is; on iOS must be swapped for libcurl/NSURLSession/libarchive implementations behind the same binding names | moderate (iOS only) | partially |

Everything else — the SwiftUI surface, the audio host, CoreMIDI glue — is new code in
iSchwung, leaving the schwung repo untouched.

## Platform notes

**macOS:** Essentially a POSIX port. `shm_open`, `fork/exec`, `dlopen` of per-module
`dsp.dylib` all work; segment names are under the 31-char macOS limit. Even the
two-process layout would work, but single-process is simpler and required for iOS anyway.

**iOS/iPadOS:** Same single-process core, plus:
- **No fork/exec** — replace the handful of subprocess bindings (above).
- **Plugins**: `dlopen` *is* allowed for signed frameworks bundled inside the app, so
  per-module dylibs can ship as embedded frameworks; alternatively statically link and
  register via a symbol table (note: every plugin exports the same
  `move_plugin_init_v2` symbol, so static linking requires per-module symbol renaming —
  bundled frameworks avoid that entirely).
- **No downloading native code** (App Store rule): the Module Store can install JS-only
  modules (~17 of 89 in the catalog) but native DSP modules must ship in the app binary.
- Files live in the app container; audio session config needed for low-latency output.

## Risks / open questions

1. **Sound generators are external repos.** In-repo sound generators are only `linein`
   and wav-player; real synths (sf2, dexed, obxd, braids…) live in separate
   `move-anything-*` repos. The DSP is plain C/C++ but each needs an Apple build. A
   first milestone should pick one (sf2/FluidLite is a good candidate) to prove the
   chain end-to-end. 72/89 catalog modules have native DSP.
2. **shadow_ui.js menus referencing dead features** (Link Audio settings, sampler,
   set pages, store-native-installs on iOS) will need either benign stub responses from
   the param layer or small UI hides. The bindings already return safe defaults in most
   cases (e.g. `host_speaker_active` reads a struct field we control).
3. **Timing model**: shadow_ui ticks at ~60 Hz and its param GET blocks-polls up to
   100 ms — fine on a dedicated thread, but param servicing must run off the audio
   thread (a control thread between callbacks, as the shim does).
4. **128-frame blocks @ 44.1 kHz (~2.9 ms)**: AVAudioEngine typically prefers larger
   buffers on iOS; render multiple 128-frame sub-blocks per callback into a small FIFO.
5. **Fonts/licensing**: Tamzen BDF fonts ship in-repo; rendering path already portable.

## Suggested phasing

1. **macOS spike**: compile QuickJS + js_display + shadow_ui.c (local-alloc SHM) into a
   macOS target; SwiftUI window with framebuffer view + clickable pads/buttons/encoders;
   no audio. Shadow UI menus should render and navigate. This validates the biggest
   reuse bet cheaply.
2. **Audio engine**: thin host + shadow_chain_mgmt + chain_host + built-in FX/MIDI-FX;
   one ported sound generator; AVAudioEngine output; param servicing so knobs edit DSP.
3. **Fidelity pass**: faithful Move layout/skin, LED palette, encoder acceleration,
   jog wheel gesture, CoreMIDI for external controllers.
4. **iOS/iPadOS target**: swap subprocess bindings, package plugins as embedded
   frameworks, audio session + AUv3 consideration.
