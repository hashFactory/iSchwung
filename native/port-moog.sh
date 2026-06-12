#!/bin/bash
# port-moog.sh - Builds the schwung-moog module (RaffoSynth Moog-style synth) for
# Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/moog-src"
DEST="$NATIVE_DIR/build/external/sound_generators/moog"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/moog/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/moog/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-moog "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP moog ($TARGET)"
# C++ plugin + C engine; clang++ compiles each by extension (engine extern-C'd by
# the plugin). No filesystem access; only host->log, matching git-schwung's offset.
clang++ -O3 -ffast-math $TARGET_FLAGS -std=c++17 -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -I"$SRC/src/dsp" \
    "$SRC/src/dsp/moog_plugin.cpp" "$SRC/src/dsp/moog_engine.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true

echo "moog ($TARGET) staged at $(dirname "$DSP_OUT")"
