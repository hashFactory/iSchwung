#!/bin/bash
# port-dexed.sh - Builds the schwung-dx7 (Dexed/msfa) sound generator for Apple
# targets and stages it (with factory .syx banks) into build/external.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/dexed-src"
DEST="$NATIVE_DIR/build/external/sound_generators/dexed"

# TARGET=macos (default), iossim or ios. Non-macos builds only swap the dylib —
# module.json/ui.js/banks staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/dexed/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/dexed/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-dx7 "$SRC"
fi

MSFA="$SRC/src/dsp/msfa"
OBJ="$NATIVE_DIR/build/obj/dexed-$TARGET"
mkdir -p "$OBJ" "$DEST/banks" "$(dirname "$DSP_OUT")"

# Exact engine source list from upstream scripts/build.sh. The msfa engine does
# no file I/O, so it compiles WITHOUT the compat overrides header.
MSFA_SRCS="dx7note.cc env.cc exp2.cc fm_core.cc fm_op_kernel.cc freqlut.cc \
lfo.cc pitchenv.cc sin.cc porta.cpp"

for name in $MSFA_SRCS; do
    src="$MSFA/$name"
    obj="$OBJ/${name%.*}.o"
    [ "$obj" -nt "$src" ] && continue
    echo "CXX msfa/$name"
    clang++ -std=c++17 -O2 $TARGET_FLAGS -fPIC -DNDEBUG \
        -I"$SRC/src/dsp" -c "$src" -o "$obj"
done

echo "DSP dexed"
# Parse libc++ before the compat macros exist — the function-like remove()/
# rename() overrides otherwise mangle libc++ declarations (std::remove etc).
cat > "$OBJ/cxx_first.h" <<'EOF'
#include <algorithm>
#include <string>
#include <memory>
#include <vector>
EOF
# Only the plugin layer touches the filesystem (banks/*.syx under the host
# module_dir), so it alone gets the path-remapping overrides.
clang++ -std=c++17 -O2 -g $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$OBJ/cxx_first.h" \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src/dsp" -I"$NATIVE_DIR" \
    "$SRC/src/dsp/dx7_plugin.cpp" "$OBJ"/*.o \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$SRC/src/ui.js" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true
# Factory .syx patch banks the upstream installer ships
cp "$SRC/banks/"*.syx "$DEST/banks/" 2>/dev/null || true

echo "dexed staged at $DEST"
