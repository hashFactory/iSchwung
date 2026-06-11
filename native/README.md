# native/ — Apple host layer for schwung's shadow UI

Builds `libschwungcore.a`: QuickJS + **unmodified** sources from `../git-schwung`
(`shadow_ui.c`, `js_display.c`, `unified_log.c`, `analytics.c`) + the Apple compat
layer. Zero changes to the schwung repo.

How the unmodified sources run on macOS:

- `apple_compat_overrides.h` is force-included (`-include`) when compiling upstream
  sources and quickjs-libc. It pre-includes system headers, then macro-remaps the
  filesystem calls (`fopen`, `stat`, `opendir`, `realpath`, `execvp`, …) to wrappers
  that translate the Move's hardcoded `/data/UserData` prefix into a per-user data
  root (`~/Library/Application Support/iSchwung/data`). `realpath` reverse-maps its
  result so upstream `validate_path()` prefix checks still pass.
- `apple_compat.c` plays the shim's role: creates the POSIX SHM segments (real
  `shm_open` — works on macOS), seeds `shadow_control_t`/`shadow_ui_state_t`,
  answers `/schwung-param` requests (stub: "slot empty" until the audio engine
  exists), and exposes a small API (`include/schwung_apple.h`, also the Swift
  bridging header) for display polling, MIDI in, and LED drain.
- `shadow_ui.c`'s `main` is renamed via `-Dmain=schwung_shadow_ui_main` and runs on
  a background thread.

Scripts:

- `./build-core.sh` — builds `build/libschwungcore.a` + font assets (Pillow venv).
  Re-run after pulling git-schwung changes that touch the compiled C files.
- `./sync-runtime.sh <data-root>` — populates the `/data/UserData` stand-in
  (JS bundle, shared mjs, fonts, logos, features.json). The app runs this on launch.
- `test/smoke_test.c` — headless boot + ASCII framebuffer dump.
- `test/peek.c` — attach to the *running app's* SHM: `peek dump`, `peek cc 14 1`,
  `peek note 68 100` … drive and inspect the UI from the CLI.

Xcode wiring (already in project.pbxproj): `SWIFT_OBJC_BRIDGING_HEADER` →
`native/include/schwung_apple.h`, `OTHER_LDFLAGS[sdk=macosx*]` →
`native/build/libschwungcore.a -framework AudioToolbox`, `ENABLE_APP_SANDBOX = NO`,
`ENABLE_HARDENED_RUNTIME = NO` (library validation would reject the ad-hoc-signed
module dylibs).

## Audio engine (phase 2)

`apple_audio_engine.c` replaces the param stub when
`modules/chain/dsp.so` exists in the data root. It reimplements the shim's audio
role per the wire contract in `src/host/shadow_chain_mgmt.c`:

- dlopens schwung's unmodified `chain_host.c` (built as a Mach-O dylib named
  `dsp.so`; `-undefined dynamic_lookup` lets its remapped fopen/dlopen calls
  resolve against the app's compat wrappers), creates 4 instances eagerly.
- Services `/schwung-param`: `slot:*` keys (volume/mute/solo/channels/transpose)
  handled engine-side; `master_fx:fxN:*` loads/controls audio-FX dylibs;
  `master_fx:lfoN:*` is a config store (no modulation yet); everything else is
  forwarded to the chain instance (`synth:module`, `load_patch`, `ui_hierarchy`,
  `chain_params`, …). Link-Audio/jack/sampler keys answer error 13, as absent.
- Watches `shadow_control_t.ui_request_id` for patch load/unload requests, and
  drains `/schwung-midi-dsp` with receive-channel dispatch + forward remap.
- Renders 128-frame blocks through a CoreAudio default-output unit; per-slot
  volume/mute/solo, then master FX. A mutex serializes plugin calls; the render
  callback trylocks and emits silence during loads. Peak is published to
  `shadow_overlay_state_t.sampler_vu_peak` (visible via `peek vu`).
- Surface pads: Move firmware would normally route these; here
  `schwung_send_internal_midi` forwards note events to the selected slot
  (track buttons update `selected_slot`), honoring `pad_block`.

Module DSP builds: `build-core.sh` compiles chain/freeverb/chord/arp/
velocity_scale and `native/modules/simple-synth` (iSchwung's own test synth) as
dylibs into `build/modules/`, and `sync-runtime.sh` installs them with their
`module.json`/JS into the data root. `shim-include/malloc.h` satisfies
chain_host's glibc-only `<malloc.h>`/`malloc_trim` without repo changes.

`test/peek.c` gained: `set/get <slot> <key> [value]` (param protocol),
`dspnote <note> <vel>`, `vu`.

## External modules

- `fetch-modules.sh` — downloads every catalog module's release tarball and
  stages the JS-only ones (no .so inside) into `build/external/`;
  `build/module-cache/native-needed.txt` lists the ~79 that need per-module
  macOS DSP ports.
- `port-sf2.sh` — the first such port: builds move-anything-sf2 (vendored
  FluidLite) as a macOS dylib and downloads the GeneralUser GS GM soundfont.
  Porting notes that generalize: FluidLite couldn't take the override header
  (its `fluid_fileapi_t` has a member literally named `fopen` — function-like
  macros mangle member calls), so the virtual path is remapped at the plugin
  boundary instead by wrapping `fluid_synth_sfload` in a force-included decl
  header. Same pattern applies to other vendored libs doing their own file I/O.
- `sync-runtime.sh` rsyncs `build/external/` into the data root's modules dir.

## iPhone (iOS Simulator)

Same code, second build flavor. `TARGET=iossim` parametrizes the scripts
(`build/iossim/` outputs; arm64-sim slice):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TARGET=iossim ./build-core.sh        # libschwungcore.a + module dylibs
TARGET=iossim ./port-sf2.sh          # sim sf2 dylib (overlay in build/iossim/external)
TARGET=iossim ./sync-runtime.sh "$PWD/build/ios-data"   # sim data root
xcodebuild -scheme iSchwung -destination 'generic/platform=iOS Simulator' build
```

Platform differences live in the compat layer, not upstream: SHM is file-backed
under `<data-root>/.shm` (iOS has no usable POSIX SHM), `fork()`/`system()` are
stubbed to ENOSYS (curl/tar helpers take their error paths), audio is RemoteIO,
and AVAudioSession is activated from Swift. The simulator sees the host
filesystem, so the app uses `native/build/ios-data` directly as its data root
(no bundling) — a real-device build would need the runtime tree bundled and the
dylibs embedded + signed. `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` keeps
xcodebuild from demanding an Intel slice of the static lib.
