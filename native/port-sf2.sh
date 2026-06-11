#!/bin/bash
# port-sf2.sh - Builds the move-anything-sf2 module (FluidLite) for macOS arm64
# and stages it (with a GM soundfont) into build/external for sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/sf2-src"
DEST="$NATIVE_DIR/build/external/sound_generators/sf2"

# TARGET=macos (default) or iossim. The iossim build only swaps the dylib —
# module.json/ui.js/soundfont staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/sf2/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/sf2/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/charlesvestal/move-anything-sf2 "$SRC"
fi

FL="$SRC/src/dsp/third_party/fluidlite"
OBJ="$NATIVE_DIR/build/obj/fluidlite-$TARGET"
mkdir -p "$OBJ" "$DEST/soundfonts" "$(dirname "$DSP_OUT")"

# Exact source list from upstream scripts/build.sh (fluid_dsp_simple.c is an
# experiment file that doesn't compile standalone).
FLUID_SRCS="fluid_chan fluid_chorus fluid_conv fluid_defsfont fluid_dsp_float \
fluid_gen fluid_hash fluid_init fluid_list fluid_mod fluid_ramsfont fluid_rev \
fluid_settings fluid_synth fluid_sys fluid_tuning fluid_voice"

# FluidLite compiles untouched (its fluid_fileapi_t has a member literally
# named "fopen", which the override macros would mangle). Soundfont paths are
# remapped at the plugin boundary instead — see sf2_decls.h below.
for name in $FLUID_SRCS; do
    src="$FL/src/$name.c"
    obj="$OBJ/$(basename "$src" .c).o"
    [ "$obj" -nt "$src" ] && continue
    echo "CC $(basename "$src")"
    clang -O3 $TARGET_FLAGS -fPIC -DNDEBUG -I"$FL/include" -I"$FL/src" -c "$src" -o "$obj"
done

echo "DSP sf2"
# fluid_synth_all_notes_off is implemented but only declared in FluidLite's
# internal headers; upstream gcc allowed the implicit declaration, clang errors.
cat > "$OBJ/sf2_decls.h" <<'EOF'
#include "fluidlite.h"
int fluid_synth_all_notes_off(fluid_synth_t *synth, int chan);

/* FluidLite opens soundfonts itself with the virtual /data/UserData path the
 * plugin hands it; remap at the call boundary (the library stays unmodified). */
const char *schwung_remap(const char *path, char *buf, unsigned long buf_len);
static inline int schwung_fluid_sfload(fluid_synth_t *s, const char *path, int reset) {
    char buf[1024];
    return (fluid_synth_sfload)(s, schwung_remap(path, buf, sizeof(buf)), reset);
}
#define fluid_synth_sfload(s, p, r) schwung_fluid_sfload((s), (p), (r))
EOF
clang -O2 -g $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -include "$OBJ/sf2_decls.h" \
    -I"$SRC/src/dsp" -I"$FL/include" -I"$NATIVE_DIR" \
    "$SRC/src/dsp/sf2_plugin.c" "$OBJ"/*.o \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$SRC/src/ui.js" "$DEST/"
cp "$SRC/src/help.json" "$DEST/" 2>/dev/null || true

# GM soundfont (GeneralUser GS, ~30 MB, free license)
SF="$DEST/soundfonts/GeneralUser-GS.sf2"
if [ ! -f "$SF" ]; then
    echo "Downloading GeneralUser GS soundfont..."
    curl -sL --max-time 300 \
        "https://github.com/mrbumpy409/GeneralUser-GS/raw/main/GeneralUser-GS.sf2" -o "$SF" \
        || echo "soundfont download failed — drop .sf2 files into the module's soundfonts/ dir"
fi

echo "sf2 staged at $DEST"
