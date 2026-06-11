#!/bin/bash
# port-plaits.sh - Builds the move-anything-plaits module (Mutable Instruments
# Plaits) for Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/plaits-src"
DEST="$NATIVE_DIR/build/external/sound_generators/plaits"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/plaits/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/plaits/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/j3threejay/move-anything-plaits "$SRC"
fi

OBJ="$NATIVE_DIR/build/obj/plaits-$TARGET"
mkdir -p "$OBJ" "$DEST" "$(dirname "$DSP_OUT")"

INCLUDES="-I$SRC/src -I$SRC/src/dsp -I$SRC/src/dsp/plaits -I$SRC/src/dsp/stmlib -I$NATIVE_DIR/shim-include"

# Plaits DSP engines + stmlib (NOT stmlib/system/, which has STM32 deps); list
# mirrors upstream scripts/build.sh. Compiled WITHOUT the compat overrides;
# -DTEST selects the non-embedded code paths.
PLAITS_SRCS="plaits/dsp/chords/chord_bank plaits/dsp/engine/additive_engine \
plaits/dsp/engine/bass_drum_engine plaits/dsp/engine/chord_engine plaits/dsp/engine/fm_engine \
plaits/dsp/engine/grain_engine plaits/dsp/engine/hi_hat_engine plaits/dsp/engine/modal_engine \
plaits/dsp/engine/noise_engine plaits/dsp/engine/particle_engine plaits/dsp/engine/snare_drum_engine \
plaits/dsp/engine/speech_engine plaits/dsp/engine/string_engine plaits/dsp/engine/swarm_engine \
plaits/dsp/engine/virtual_analog_engine plaits/dsp/engine/waveshaping_engine plaits/dsp/engine/wavetable_engine \
plaits/dsp/engine2/chiptune_engine plaits/dsp/engine2/phase_distortion_engine plaits/dsp/engine2/six_op_engine \
plaits/dsp/engine2/string_machine_engine plaits/dsp/engine2/virtual_analog_vcf_engine plaits/dsp/engine2/wave_terrain_engine \
plaits/dsp/fm/algorithms plaits/dsp/fm/dx_units plaits/dsp/physical_modelling/modal_voice \
plaits/dsp/physical_modelling/resonator plaits/dsp/physical_modelling/string plaits/dsp/physical_modelling/string_voice \
plaits/dsp/speech/lpc_speech_synth plaits/dsp/speech/lpc_speech_synth_controller plaits/dsp/speech/lpc_speech_synth_phonemes \
plaits/dsp/speech/lpc_speech_synth_words plaits/dsp/speech/naive_speech_synth plaits/dsp/speech/sam_speech_synth \
plaits/dsp/voice plaits/resources stmlib/dsp/atan stmlib/dsp/units stmlib/utils/random"

for name in $PLAITS_SRCS; do
    src="$SRC/src/dsp/$name.cc"
    obj="$OBJ/$(echo "$name" | tr / _).o"
    [ -f "$obj" ] && [ "$obj" -nt "$src" ] && continue
    echo "CXX $name"
    clang++ -O3 $TARGET_FLAGS -fPIC -std=c++14 -DNDEBUG -DTEST $INCLUDES -c "$src" -o "$obj"
done

echo "DSP plaits"
# Plaits is self-contained (compiled-in lookup tables, no runtime file IO), so
# the plugin layer needs no compat overrides — and skipping them avoids the
# `#define remove` macro clashing with libc++'s std::remove via <algorithm>.
clang++ -O2 -g $TARGET_FLAGS -std=c++14 -dynamiclib -undefined dynamic_lookup -DNDEBUG -DTEST \
    $INCLUDES \
    "$SRC/src/dsp/plaits_plugin.cpp" "$OBJ"/*.o \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true
cp "$SRC/src/ui.js" "$DEST/" 2>/dev/null || true
for d in presets chain_patches; do
    if [ -d "$SRC/src/$d" ]; then
        mkdir -p "$DEST/$d"
        cp "$SRC/src/$d/"* "$DEST/$d/"
    fi
done

echo "plaits ($TARGET) staged at $(dirname "$DSP_OUT")"
