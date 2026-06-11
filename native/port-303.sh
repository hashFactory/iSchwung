#!/bin/bash
# port-303.sh - Builds the schwung-303 module (Open303 TB-303 emulation) for
# Apple targets and stages it into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/303-src"
DEST="$NATIVE_DIR/build/external/sound_generators/303"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/303/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/303/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-303 "$SRC"
fi

OBJ="$NATIVE_DIR/build/obj/303-$TARGET"
mkdir -p "$OBJ" "$DEST" "$(dirname "$DSP_OUT")"

INCLUDES="-I$SRC/src/dsp -I$SRC/src/dsp/open303 -I$NATIVE_DIR/shim-include"

# Open303 library: C (fft4g) + C++ (rosic_*). Compiled WITHOUT compat overrides.
for c in "$SRC"/src/dsp/open303/*.c; do
    obj="$OBJ/$(basename "${c%.c}").o"
    [ -f "$obj" ] && [ "$obj" -nt "$c" ] && continue
    echo "CC $(basename "$c")"
    clang -O3 $TARGET_FLAGS -fPIC -std=c99 $INCLUDES -c "$c" -o "$obj"
done
for cc in "$SRC"/src/dsp/open303/*.cpp; do
    obj="$OBJ/$(basename "${cc%.cpp}").o"
    [ -f "$obj" ] && [ "$obj" -nt "$cc" ] && continue
    echo "CXX $(basename "$cc")"
    clang++ -O3 $TARGET_FLAGS -fPIC -std=c++17 -Wno-sign-compare $INCLUDES -c "$cc" -o "$obj"
done

echo "DSP 303"
# Self-contained (no runtime file IO), so no compat overrides on the plugin —
# also avoids the `#define remove` macro clashing with libc++ via <algorithm>.
clang++ -O2 -g $TARGET_FLAGS -std=c++17 -dynamiclib -undefined dynamic_lookup \
    -Wno-sign-compare \
    $INCLUDES \
    "$SRC/src/dsp/plugin.cpp" "$OBJ"/*.o \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/ui.js" "$DEST/" 2>/dev/null || true
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true
for d in presets chain_patches; do
    if [ -d "$SRC/src/$d" ]; then
        mkdir -p "$DEST/$d"
        cp "$SRC/src/$d/"* "$DEST/$d/"
    fi
done

echo "303 ($TARGET) staged at $(dirname "$DSP_OUT")"
