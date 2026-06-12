#!/bin/bash
# port-filter.sh - Builds the schwung-filter module (multi-mode SVF / Schwoog
# filter with envelope follower + tempo-synced LFO) for Apple targets and stages
# it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/filter-src"
DEST="$NATIVE_DIR/build/external/audio_fx/filter"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; OUT_DIR="$DEST" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/iossim/external/audio_fx/filter" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/ios/external/audio_fx/filter" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-filter "$SRC"
fi

mkdir -p "$DEST" "$OUT_DIR"

echo "DSP filter ($TARGET)"
# Multi-TU in-chain FX (filter.c + svf_core/modulation/smoother/model_moog), no
# filesystem access; bundled audio_fx_api_v1.h.
clang -O3 -ffast-math $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -I"$SRC/src/dsp" \
    "$SRC/src/dsp/filter.c" \
    "$SRC/src/dsp/svf_core.c" \
    "$SRC/src/dsp/modulation.c" \
    "$SRC/src/dsp/smoother.c" \
    "$SRC/src/dsp/model_moog.c" \
    -o "$OUT_DIR/dsp.so" -lm
# chain_host loads in-chain FX as audio_fx/<id>/<module.json dsp> — ship both names.
cp "$OUT_DIR/dsp.so" "$OUT_DIR/filter.so"

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true

echo "filter ($TARGET) staged at $OUT_DIR"
