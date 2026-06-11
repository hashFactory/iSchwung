#!/bin/bash
# port-braids.sh - Builds the schwung-braids module (Mutable Instruments Braids)
# for Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/braids-src"
DEST="$NATIVE_DIR/build/external/sound_generators/braids"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/presets staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/braids/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/braids/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-braids "$SRC"
fi

OBJ="$NATIVE_DIR/build/obj/braids-$TARGET"
mkdir -p "$OBJ" "$DEST" "$(dirname "$DSP_OUT")"

# Vendored Braids/stmlib sources from upstream scripts/build.sh; -DTEST selects
# the non-embedded code paths. Compiled WITHOUT the compat overrides.
BRAIDS_SRCS="braids/macro_oscillator braids/analog_oscillator \
braids/digital_oscillator braids/resources braids/quantizer stmlib/utils/random"

for name in $BRAIDS_SRCS; do
    src="$SRC/src/dsp/$name.cc"
    obj="$OBJ/$(basename "$src" .cc).o"
    [ "$obj" -nt "$src" ] && continue
    echo "CXX $(basename "$src")"
    clang++ -O3 $TARGET_FLAGS -fPIC -std=c++14 -DNDEBUG -DTEST \
        -I"$SRC/src/dsp" -I"$NATIVE_DIR/shim-include" -c "$src" -o "$obj"
done

echo "DSP braids"
# Plugin layer loads presets from its module_dir (a /data/UserData path on the
# host); compat overrides remap those fopen/opendir calls.
clang++ -O2 -g $TARGET_FLAGS -std=c++14 -dynamiclib -undefined dynamic_lookup -DNDEBUG -DTEST \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src/dsp" -I"$NATIVE_DIR/shim-include" \
    "$SRC/src/dsp/braids_plugin.cpp" "$OBJ"/*.o \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true
for d in presets chain_patches; do
    if [ -d "$SRC/src/$d" ]; then
        mkdir -p "$DEST/$d"
        cp "$SRC/src/$d/"* "$DEST/$d/"
    fi
done

echo "braids ($TARGET) staged at $(dirname "$DSP_OUT")"
