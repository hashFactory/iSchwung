#!/bin/bash
# port-hera.sh - Builds the schwung-hera module (Juno-106-style synth with BBD
# chorus) for Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/hera-src"
DEST="$NATIVE_DIR/build/external/sound_generators/hera"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/ui/presets staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/hera/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/hera/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-hera "$SRC"
fi

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP hera ($TARGET)"
# 7 C++ TUs (plugin + Engine: envelope/LFO/tables/BBD chorus). Reads preset XML
# from its module dir, so fopen is remapped to reach the data root. Uses the
# fopen-only shim, not the full overrides, whose remove()/open() macros collide
# with the STL (this code uses std::remove). Only host->log is called (early
# offset), so no host-header override.
clang++ -O3 $TARGET_FLAGS -std=c++14 -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_fopen_only.h" \
    -I"$SRC/src/dsp" -I"$SRC/src/dsp/Engine" \
    "$SRC/src/dsp/hera_plugin.cpp" \
    "$SRC/src/dsp/Engine/HeraEnvelope.cpp" \
    "$SRC/src/dsp/Engine/HeraLFO.cpp" \
    "$SRC/src/dsp/Engine/HeraLFOWithEnvelope.cpp" \
    "$SRC/src/dsp/Engine/HeraTables.cpp" \
    "$SRC/src/dsp/Engine/bbd_line.cpp" \
    "$SRC/src/dsp/Engine/bbd_filter.cpp" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/ui.js"       "$DEST/"
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true
if [ -d "$SRC/src/presets" ]; then
    mkdir -p "$DEST/presets"
    cp "$SRC/src/presets/"* "$DEST/presets/"
fi

echo "hera ($TARGET) staged at $(dirname "$DSP_OUT")"
