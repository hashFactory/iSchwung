#!/bin/bash
# port-euclidrum.sh - Builds the euclidrum-move module (8-lane generative
# Euclidean drum sequencer MIDI FX) for Apple targets and stages it into
# build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/euclidrum-src"
DEST="$NATIVE_DIR/build/external/midi_fx/euclidrum"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/help.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/midi_fx/euclidrum/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/midi_fx/euclidrum/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/filliformes/euclidrum-move "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP euclidrum ($TARGET)"
# Single-file MIDI FX. Entry symbol move_midi_fx_init. The only hardcoded
# /data/UserData path is a debug log (EUCLIDRUM_DEBUG_LOG=0, compiled out), but
# we still force-include the overrides header to remap any fs call at the plugin
# boundary, matching the established pattern. Host headers live in git-schwung/src.
clang -O2 $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$NATIVE_DIR/../git-schwung/src" \
    "$SRC/euclidrum.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/module.json" "$DEST/"
cp "$SRC/help.json" "$DEST/" 2>/dev/null || true

echo "euclidrum ($TARGET) staged at $(dirname "$DSP_OUT")"
