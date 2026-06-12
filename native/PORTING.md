# Module porting tracker

Status of porting the Schwung **Module Store** catalog to Apple targets. The
catalog's prebuilt `.so` are ARM-Linux and won't load on macOS/iOS, so each
module's DSP needs a per-target recompile via a `native/port-<id>.sh` script (the
JS UI travels as-is). See [`README.md`](README.md) for how a port is built.

**Progress: 23 / 79 native ports done.** (Plus 10 JS-only catalog modules that
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
| ottx | ⬜ | ★★ | High | legsmechanical/schwung-ottx | OTT multiband comp |
| vocoder | ⬜ | ★★ | High | charlesvestal/schwung-vocoder | vocoder |
| cloudseed | ⬜ | ★★ | High | charlesvestal/schwung-cloudseed | algorithmic reverb (C++) |
| chowtape | ⬜ | ★★ | High | charlesvestal/schwung-chowtape | ChowDSP tape (C++) |
| dragonfly-hall | ⬜ | ★★ | High | wolfrenegade1976/move-anything-dragonfly-hall | Dragonfly hall reverb |
| clap | ⬜ | ★★ | High | charlesvestal/schwung-airwindows | Airwindows collection |
| superboom | ⬜ | ★ | Med | filliformes/super-boom-move | bass enhancer |
| punchfx | ⬜ | ★ | Med | filliformes/punchfx-move | transient/punch |
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
| branchage | ⬜ | ★ | Med | broduoliviercontact-web/Schwung-Midi-Fx-branchages-Multi-Random-generator | random generator |
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
| chordism | ⬜ | ★ | Med | charlesvestal/schwung-chordism | chord synth |
| wurl | ⬜ | ★★ | High | filliformes/wurl-move | Wurlitzer EP |
| moog | ⬜ | ★★ | High | charlesvestal/schwung-moog | Moog model |
| hera | ⬜ | ★★ | High | charlesvestal/schwung-hera | Juno-106 |
| hush1 | ⬜ | ★★ | Med | charlesvestal/schwung-hush1 | — |
| sfz | ⬜ | ★★ | Med | charlesvestal/schwung-sfz | SFZ player (samples) |
| mrdrums | ⬜ | ★★ | Med | handcraftedcc/move-everything-mrdrums | drum machine |
| krautdrums | ⬜ | ★★ | Med | filliformes/krautdrums-move | drum synth |
| po32-drum | ⬜ | ★★ | Med | mestela/schwung-libpo32 | PO-32 |
| granny | ⬜ | ★★ | Med | handcraftedcc/move-everything-granny | granular synth |
| freak | ⬜ | ★★ | Med | handcraftedcc/move-everything-mrhyde | — |
| slicer | ⬜ | ★★ | Med | j3threejay/move-anything-slicer | sample slicer |
| breakbeat | ⬜ | ★★ | Med | mestela/schwung-breakbeat | breakbeat slicer (samples) |
| denis | ⬜ | ★★ | Med | filliformes/denis-move | — |
| essaim | ⬜ | ★★ | Med | filliformes/essaim-move | — |
| forge | ⬜ | ★★ | Med | filliformes/forge-move | — |
| signal | ⬜ | ★★ | Med | filliformes/signal-move | — |
| weird-dreams | ⬜ | ★★ | Med | filliformes/weird-dreams-move | — |
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
Best ratio first: **chordism** (★ synth), **superboom**, **punchfx** (★ FX),
**branchage** (★ MIDI), then the ★★ High-impact batch: **ottx**, **vocoder**,
**cloudseed**, **wurl**, **moog**, **hera**.
