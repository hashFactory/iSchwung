#!/bin/bash
# port-midiverb.sh - Builds the schwung-midiverb module (Alesis Midiverb emu)
# for Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/midiverb-src"
DEST="$NATIVE_DIR/build/external/audio_fx/midiverb"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; OUT_DIR="$DEST" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/iossim/external/audio_fx/midiverb" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            OUT_DIR="$NATIVE_DIR/build/ios/external/audio_fx/midiverb" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-midiverb "$SRC"
fi

mkdir -p "$DEST" "$OUT_DIR"

echo "DSP midiverb ($TARGET)"
# All sources are the module's own; midiverb_core.c fopen()s optional ROM dumps
# from the (virtual /data/UserData) module dir, so the compat overrides apply.
clang -O3 -ffast-math $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src/dsp" \
    "$SRC/src/dsp/plugin.c" \
    "$SRC/src/dsp/midiverb_core.c" \
    "$SRC/src/dsp/resampler.c" \
    -o "$OUT_DIR/dsp.so" -lm
# chain_host loads in-chain FX as audio_fx/<id>/<id>.so (module.json "dsp")
cp "$OUT_DIR/dsp.so" "$OUT_DIR/midiverb.so"

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true
mkdir -p "$DEST/roms"   # optional EPROM dumps slot (see module.json assets)

echo "midiverb ($TARGET) staged at $OUT_DIR"
