#!/bin/bash
# port-hush1.sh - Builds the schwung-hush1 module (SH-101-style mono synth) for
# Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/hush1-src"
DEST="$NATIVE_DIR/build/external/sound_generators/hush1"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/ui staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/hush1/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/hush1/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-hush1 "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP hush1 ($TARGET)"
# 6 C TUs (plugin + osc/lfo/env/filter/control). VST-preset import does fopen on a
# user path, so the compat overrides are force-included to remap /data/UserData.
# Only host->log / host->sample_rate (early offsets), so no host-header override.
clang -O3 -ffast-math $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src" -I"$SRC/src/dsp" \
    "$SRC/src/dsp/sh101_plugin.c" "$SRC/src/dsp/sh101_osc.c" "$SRC/src/dsp/sh101_lfo.c" \
    "$SRC/src/dsp/sh101_env.c" "$SRC/src/dsp/sh101_filter.c" "$SRC/src/dsp/sh101_control.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/ui.js"       "$DEST/" 2>/dev/null || true
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true

echo "hush1 ($TARGET) staged at $(dirname "$DSP_OUT")"
