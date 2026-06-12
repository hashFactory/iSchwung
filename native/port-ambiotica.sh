#!/bin/bash
# port-ambiotica.sh - Builds the schwung-ambiotica module (ambient reverb /
# granular / looper FX) for Apple targets and stages it into build/external for
# sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/ambiotica-src"
DEST="$NATIVE_DIR/build/external/audio_fx/ambiotica"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; OUT_DIR="$DEST" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/iossim/external/audio_fx/ambiotica" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/ios/external/audio_fx/ambiotica" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-ambiotica "$SRC"
fi

mkdir -p "$DEST" "$OUT_DIR"

echo "DSP ambiotica ($TARGET)"
# Multi-TU in-chain FX (plugin + reverb/granular/looper/microloop/lfo), no
# filesystem access; bundled audio_fx_api_v2.h.
clang -O3 -ffast-math $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -I"$SRC/src/dsp" \
    "$SRC/src/dsp/plugin.c" "$SRC/src/dsp/reverb.c" "$SRC/src/dsp/granular.c" \
    "$SRC/src/dsp/looper.c" "$SRC/src/dsp/microloop.c" "$SRC/src/dsp/lfo.c" \
    -o "$OUT_DIR/dsp.so" -lm
# chain_host loads in-chain FX as audio_fx/<id>/<module.json dsp> — ship both names.
cp "$OUT_DIR/dsp.so" "$OUT_DIR/ambiotica.so"

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true

echo "ambiotica ($TARGET) staged at $OUT_DIR"
