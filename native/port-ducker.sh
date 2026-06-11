#!/bin/bash
# port-ducker.sh - Builds the schwung-ducker module (MIDI-triggered sidechain
# ducker) for Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/ducker-src"
DEST="$NATIVE_DIR/build/external/audio_fx/ducker"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; OUT_DIR="$DEST" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/iossim/external/audio_fx/ducker" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/ios/external/audio_fx/ducker" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-ducker "$SRC"
fi

mkdir -p "$DEST" "$OUT_DIR"

echo "DSP ducker ($TARGET)"
# Single-file plugin, no filesystem access; -O3 -ffast-math (upstream -Ofast, sans the
# Cortex-A72 -march/-mtune flags, which don't apply here).
clang -O3 -ffast-math $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -I"$SRC/src/dsp" \
    "$SRC/src/dsp/ducker.c" \
    -o "$OUT_DIR/dsp.so" -lm
# chain_host loads in-chain FX as audio_fx/<id>/<id>.so (module.json "dsp")
cp "$OUT_DIR/dsp.so" "$OUT_DIR/ducker.so"

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true

echo "ducker ($TARGET) staged at $OUT_DIR"
