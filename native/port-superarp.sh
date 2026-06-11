#!/bin/bash
# port-superarp.sh - Builds the move-everything-superarp module (advanced
# arpeggiator with progression patterns & rhythm presets, MIDI FX) for Apple
# targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/superarp-src"
DEST="$NATIVE_DIR/build/external/midi_fx/superarp"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/help.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/midi_fx/superarp/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/midi_fx/superarp/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/handcraftedcc/move-everything-superarp "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP superarp ($TARGET)"
# Single-file MIDI FX, entry symbol move_midi_fx_init. Progression/rhythm
# presets are enums baked into the source — nothing to stage. At create_instance
# it fopen()s "<module_dir>/module.json" to cache chain_params; module_dir is a
# real on-disk path on Apple, so the force-included overrides header routes that
# fopen through schwung_compat_fopen unchanged. The /data/UserData debug log is
# behind SUPERARP_DEBUG_LOG=0 (compiled out). Host headers live in git-schwung/src.
clang -O3 $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src" -I"$SRC/src/dsp" -I"$NATIVE_DIR/../git-schwung/src" \
    "$SRC/src/dsp/superarp.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true

echo "superarp ($TARGET) staged at $(dirname "$DSP_OUT")"
