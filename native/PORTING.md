# Module porting tracker

Status of porting the Schwung **Module Store** catalog to Apple targets. The
catalog's prebuilt `.so` are ARM-Linux and won't load on macOS/iOS, so each
module's DSP needs a per-target recompile via a `native/port-<id>.sh` script (the
JS UI travels as-is). See [`README.md`](README.md) for how a port is built.

**Progress: 41 / 79 native ports done.** (Plus 10 JS-only catalog modules that
already work, and the built-ins below.)

### Legend
- **Status** — ✅ ported & verified · 🚧 in progress · ⬜ todo
- **Effort** — ★ single-file C, no assets · ★★ multi-file / C++ / bundled
  presets · ★★★ large C++ engine, network, subprocess, ML models, or big sample
  payloads. *For un-ported rows this is an estimate until the repo is probed.*
- **Impact** — rough musical usefulness in a standalone groovebox (High/Med/Low).

When you finish a port, flip its Status to ✅ and correct Effort to what it
actually took.

---

## Built-in (work out of the box)
Shipped inside upstream Schwung and staged by `sync-runtime.sh` — no port needed:
`chain`, `simple-synth`, `freeverb`, `linein`, `wav-player`, and the `chord` /
`arp` / `velocity_scale` MIDI FX.

## JS-only catalog modules (work as-is)
No native DSP, so `native/fetch-modules.sh` stages them directly:
`ai-assistant`, `ai-manual`, `chorddex`, `control`, `dronage-tool`, `fork`,
`juno_control`, `m8`, `sidcontrol`, `stems`.

---

## Audio FX

| Module | Status | Effort | Impact | Repo | Notes |
|--------|:--:|:--:|:--:|------|-------|
| ducker | ✅ | ★ | Med | charlesvestal/schwung-ducker | sidechain ducker |
| filter | ✅ | ★★ | High | charlesvestal/schwung-filter | multi-mode SVF + LFO/env |
| gate | ✅ | ★ | Med | charlesvestal/schwung-gate | noise gate |
| junologue-chorus | ✅ | ★ | High | charlesvestal/schwung-junologue-chorus | Juno chorus |
| midiverb | ✅ | ★ | Med | charlesvestal/schwung-midiverb | Midiverb-style reverb |
| mverb | ✅ | ★ | High | charlesvestal/schwung-mverb | plate/hall reverb |
| psxverb | ✅ | ★ | Med | charlesvestal/schwung-psxverb | PSX SPU reverb |
| tapedelay | ✅ | ★ | High | charlesvestal/schwung-space-delay | tape/space delay |
| usefulity | ✅ | ★ | Med | charlesvestal/schwung-usefulity | stereo utility |
| ambiotica | ✅ | ★★ | Med | charlesvestal/schwung-ambiotica | ambient reverb/granular/looper |
| ottx | ✅ | ★ | High | legsmechanical/schwung-ottx | OTT multiband comp (single-file) |
| vocoder | ✅ | ★ | High | charlesvestal/schwung-vocoder | vocoder |
| superboom | ✅ | ★ | Med | filliformes/super-boom-move | bass enhancer |
| punchfx | ✅ | ★ | Med | filliformes/punchfx-move | transient/punch |
| cloudseed | ✅ | ★ | High | charlesvestal/schwung-cloudseed | algorithmic reverb (single-file C) |
| chowtape | ✅ | ★ | High | charlesvestal/schwung-chowtape | ChowDSP tape (single-file C) |
| dragonfly-hall | ⬜ | ★★★ | High | wolfrenegade1976/move-anything-dragonfly-hall | needs external dragonfly-reverb + DPF/freeverb/kiss_fft |
| clap | ⬜ | ★★ | High | charlesvestal/schwung-airwindows | Airwindows collection |
| tapescam | ⬜ | ★★ | Med | charlesvestal/schwung-tapescam | lo-fi tape |
| granular | ⬜ | ★★ | Med | filliformes/boris-move | granular fx |
| spectra | ⬜ | ★★ | Med | filliformes/spectra-move | spectral fx |
| structor | ⬜ | ★★ | Med | filliformes/structor-move | — |
| dissolver | ⬜ | ★★ | Med | filliformes/dissolver-move | — |
| verglas | ⬜ | ★★ | Med | filliformes/verglas-move | — |
| keydetect | ⬜ | ★ | Low | charlesvestal/schwung-keydetect | key detection (analysis) |
| nam | ⬜ | ★★★ | Med | charlesvestal/schwung-nam | Neural Amp Modeler (ML) |

## MIDI FX

| Module | Status | Effort | Impact | Repo | Notes |
|--------|:--:|:--:|:--:|------|-------|
| eucalypso | ✅ | ★ | Med | handcraftedcc/move-everything-eucalypso | euclid variant |
| euclidrum | ✅ | ★ | High | filliformes/euclidrum-move | euclidean drums |
| genera | ✅ | ★ | High | filliformes/genera-move | generative seq |
| superarp | ✅ | ★ | High | handcraftedcc/move-everything-superarp | arp |
| branchage | ✅ | ★★ | Med | broduoliviercontact-web/Schwung-Midi-Fx-branchages-Multi-Random-generator | Grids-style random gen; host-header override |
| midi-player | ⬜ | ★★ | Low | charlesvestal/schwung-midi-player | needs .mid files |
| impressive-chords | ⬜ | ★★★ | Med | mestela/schwung-impressive-chords | needs presets + python codegen |

## Sound generators

| Module | Status | Effort | Impact | Repo | Notes |
|--------|:--:|:--:|:--:|------|-------|
| 303 | ✅ | ★★ | High | charlesvestal/schwung-303 | TB-303 |
| braids | ✅ | ★★ | High | charlesvestal/schwung-braids | Mutable Braids |
| dexed | ✅ | ★★ | High | charlesvestal/schwung-dx7 | DX7 FM |
| obxd | ✅ | ★★ | High | charlesvestal/schwung-obxd | OB-Xd |
| plaits | ✅ | ★★ | High | j3threejay/move-anything-plaits | Mutable Plaits |
| sf2 | ✅ | ★★ | High | charlesvestal/schwung-sf2 | SoundFont player |
| nusaw | ✅ | ★ | High | charlesvestal/schwung-nusaw | supersaw |
| chiptune | ✅ | ★★ | High | charlesvestal/schwung-chiptune | NES+GB APU; nes_snd_emu submodule |
| chordism | ✅ | ★ | Med | charlesvestal/schwung-chordism | chord synth |
| wurl | ✅ | ★ | High | filliformes/wurl-move | Wurlitzer EP (single-file C) |
| moog | ✅ | ★★ | High | charlesvestal/schwung-moog | RaffoSynth Moog; C++ plugin + C engine |
| hera | ✅ | ★★ | High | charlesvestal/schwung-hera | Juno-106 + BBD chorus; 56 presets, fopen shim |
| hush1 | ✅ | ★★ | Med | charlesvestal/schwung-hush1 | SH-101 synth, 6 TUs |
| krautdrums | ✅ | ★ | Med | filliformes/krautdrums-move | synthesized drums (single-file) |
| denis | ✅ | ★ | Med | filliformes/denis-move | synth (single-file C) |
| signal | ✅ | ★ | Med | filliformes/signal-move | synth (single-file C) |
| forge | ✅ | ★ | Med | filliformes/forge-move | synth; persists kits.dat |
| essaim | ✅ | ★ | Med | filliformes/essaim-move | synth; uses midi_send_internal |
| weird-dreams | ✅ | ★ | Med | filliformes/weird-dreams-move | synth; persists kits.dat |
| sfz | ⬜ | ★★ | Med | charlesvestal/schwung-sfz | SFZ player (samples) |
| mrdrums | ⬜ | ★★★ | Low | handcraftedcc/move-everything-mrdrums | sample drums — needs Move UserLibrary (empty here) |
| po32-drum | ⬜ | ★★ | Med | mestela/schwung-libpo32 | PO-32 |
| granny | ⬜ | ★★ | Med | handcraftedcc/move-everything-granny | granular synth |
| freak | ⬜ | ★★ | Med | handcraftedcc/move-everything-mrhyde | — |
| slicer | ⬜ | ★★ | Med | j3threejay/move-anything-slicer | sample slicer |
| breakbeat | ⬜ | ★★ | Med | mestela/schwung-breakbeat | breakbeat slicer (samples) |
| mrsample | ⬜ | ★★★ | Med | charlesvestal/schwung-mrsample | sampler (samples/subprocess) |
| minijv | ⬜ | ★★★ | Med | charlesvestal/schwung-jv880 | JV-880 (needs ROM) |
| rex | ⬜ | ★★ | Low | charlesvestal/schwung-rex | ReCycle player |
| helm | ⬜ | ★★★ | High | andree182/schwung-helm | Helm synth (big C++) |
| surge | ⬜ | ★★★ | High | charlesvestal/schwung-surge | Surge XT (massive C++) |
| osirus | ⬜ | ★★★ | High | charlesvestal/schwung-virus | Virus emulation |
| airplay | ⬜ | ★★★ | Low | charlesvestal/schwung-airplay | AirPlay receiver (network) |
| webstream | ⬜ | ★★★ | Low | charlesvestal/schwung-webstream | web audio stream (network) |
| radiogarden | ⬜ | ★★★ | Low | charlesvestal/schwung-radiogarden | internet radio (network) |
| streamrtsp | ⬜ | ★★★ | Low | handcraftedcc/schwung-StreamRTSP | RTSP stream (network) |

## Tools

| Module | Status | Effort | Impact | Repo | Notes |
|--------|:--:|:--:|:--:|------|-------|
| davebox | ✅ | ★★★ | High | legsmechanical/schwung-davebox | 8-track seq; standalone caveats in README |
| tb3po | ⬜ | ★★ | Med | charlesvestal/schwung-tb3po | 303 sequencer |
| performance-fx | ⬜ | ★★ | Med | charlesvestal/schwung-performance-fx | performance FX |
| dj | ⬜ | ★★★ | Med | djhardrich/move-anything-dj | DJ tool |
| tuner | ⬜ | ★★ | Low | CatsAreCool710/Move-Everything-Tuner | chromatic tuner |
| guitar-tuner | ⬜ | ★★ | Low | eightfour-dev/schwung-guitar-tuner | guitar tuner |
| samplerobot | ⬜ | ★★★ | Low | charlesvestal/schwung-autosample | auto-sampler (subprocess) |
| stretch | ⬜ | ★★★ | Low | charlesvestal/schwung-stretch | time-stretch (subprocess) |
| twinsampler | ⬜ | ★★★ | Low | jrucho/schwung-twinsampler | sampler (subprocess) |
| waveform-editor | ⬜ | ★★★ | Low | charlesvestal/schwung-waveform-editor | editor (subprocess) |

---

## Next up (high impact ÷ low effort)
Remaining FX: **clap** (Airwindows), **tapescam**, the filliformes set
(**spectra**, **structor**, **dissolver**, **verglas**, **granular**).
**dragonfly-hall** is high-value but needs the external dragonfly-reverb repo
(DPF/freeverb/kiss_fft) compiled in — a bigger lift. Synth-wise, **freak** is a
Plaits variant (reuse the plaits recipe); the big C++ engines (**helm**,
**surge**, **osirus**) and the **sample-based** modules (sfz, mrsample, slicer,
breakbeat, mrdrums — all need sample/ROM content absent in standalone) are lower
priority. Network/streaming + subprocess tools last.

> **C++ tip:** force-include `apple_compat_fopen_only.h` (not the full
> `apple_compat_overrides.h`) for any STL-using module — the full header's
> `remove()`/`open()` macros collide with `std::remove` etc.
