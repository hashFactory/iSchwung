#!/bin/bash
# port-genera.sh - Builds the genera-move module (generative note & chord
# sequencer MIDI FX, 7 gen modes / 20 scales) for Apple targets and stages it
# into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/genera-src"
DEST="$NATIVE_DIR/build/external/midi_fx/genera"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/help.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/midi_fx/genera/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/midi_fx/genera/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/filliformes/genera-move "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP genera ($TARGET)"
# Single-file MIDI FX, entry symbol move_midi_fx_init. No filesystem access
# (module_dir is ignored; the 20 scales are hardcoded, no presets shipped). We
# still force-include the overrides header to remap any fs call at the plugin
# boundary, matching the established pattern. Host headers live in git-schwung/src.
clang -O2 $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$NATIVE_DIR/../git-schwung/src" \
    "$SRC/genera.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/module.json" "$DEST/"
cp "$SRC/help.json" "$DEST/" 2>/dev/null || true

echo "genera ($TARGET) staged at $(dirname "$DSP_OUT")"
