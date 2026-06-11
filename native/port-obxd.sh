#!/bin/bash
# port-obxd.sh - Builds the schwung-obxd (OB-X virtual analog) sound generator
# for Apple targets and stages it (with factory.fxb) into build/external.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/obxd-src"
DEST="$NATIVE_DIR/build/external/sound_generators/obxd"

# TARGET=macos (default), iossim or ios. Non-macos builds only swap the dylib —
# module.json/ui.js/presets staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/obxd/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/obxd/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/schwung-obxd "$SRC"
fi

OBJ="$NATIVE_DIR/build/obj/obxd-$TARGET"
mkdir -p "$OBJ" "$DEST/presets" "$(dirname "$DSP_OUT")"

echo "DSP obxd"
# Parse libc++ before the compat macros exist — the function-like remove()/
# rename() overrides otherwise mangle libc++ declarations (std::remove etc).
cat > "$OBJ/cxx_first.h" <<'EOF'
#include <algorithm>
#include <string>
#include <memory>
#include <vector>
EOF
# Single TU: the header-only Engine/ is included by the plugin. The plugin layer
# reads presets/*.fxb under the host module_dir, hence the compat overrides.
clang++ -std=c++17 -O2 -g $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$OBJ/cxx_first.h" \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src/dsp" -I"$NATIVE_DIR" \
    "$SRC/src/dsp/obxd_plugin.cpp" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$SRC/src/ui.js" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true
# Factory preset bank the upstream installer ships
cp "$SRC/src/presets/"*.fxb "$DEST/presets/" 2>/dev/null || true

echo "obxd staged at $DEST"
