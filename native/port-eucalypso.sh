#!/bin/bash
# port-eucalypso.sh - Builds the move-everything-eucalypso module (Euclidean
# sequencer MIDI FX) for Apple targets and stages it into build/external for
# sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/eucalypso-src"
DEST="$NATIVE_DIR/build/external/midi_fx/eucalypso"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/help.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/midi_fx/eucalypso/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/midi_fx/eucalypso/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/handcraftedcc/move-everything-eucalypso "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP eucalypso ($TARGET)"
# Single-file MIDI FX. Entry symbol move_midi_fx_init. Two fopen sites: a debug
# log at hardcoded /data/UserData (EUCALYPSO_DEBUG_LOG=1) and a runtime read of
# module.json under the real module_dir. Force-including the overrides header
# remaps the /data path while passing the module_dir read through unchanged.
# Upstream uses -I src -I src/dsp; host headers live in git-schwung/src.
clang -O3 $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src" -I"$SRC/src/dsp" \
    -I"$NATIVE_DIR/../git-schwung/src" \
    "$SRC/src/dsp/eucalypso.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true

# Ship chain patches if upstream provides them.
if [ -d "$SRC/src/chain_patches" ]; then
    mkdir -p "$DEST/chain_patches"
    cp "$SRC/src/chain_patches"/*.json "$DEST/chain_patches/" 2>/dev/null || true
fi

echo "eucalypso ($TARGET) staged at $(dirname "$DSP_OUT")"
