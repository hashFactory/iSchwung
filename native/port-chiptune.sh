#!/bin/bash
# port-chiptune.sh - Builds the schwung-chiptune module (NES + Game Boy APU
# chip synth) for Apple targets and stages it into build/external for
# sync-runtime.sh. Pulls the nes_snd_emu git submodule.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$NATIVE_DIR/build/ports/chiptune-src"
DEST="$NATIVE_DIR/build/external/sound_generators/chiptune"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/patch staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/sound_generators/chiptune/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/sound_generators/chiptune/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/charlesvestal/schwung-chiptune "$SRC"
fi
# nes_snd_emu is a submodule (jamesathey/Nes_Snd_Emu); a plain clone leaves it empty.
if [ ! -f "$SRC/src/libs/nes_snd_emu/nes_apu/Nes_Apu.cpp" ]; then
    git -C "$SRC" submodule update --init --depth 1 src/libs/nes_snd_emu
fi

OBJ="$NATIVE_DIR/build/obj/chiptune-$TARGET"
mkdir -p "$OBJ" "$DEST" "$(dirname "$DSP_OUT")"

# NES APU library — normal visibility (its Blip_Buffer stays the global one).
for s in Nes_Apu Nes_Oscs Blip_Buffer; do
    clang++ -O3 $TARGET_FLAGS -fPIC -std=c++14 -DNDEBUG \
        -I"$SRC/src/libs/nes_snd_emu" \
        -c "$SRC/src/libs/nes_snd_emu/nes_apu/$s.cpp" -o "$OBJ/$s.o"
done
# GB APU library — hidden visibility so its duplicate Blip_Buffer/Multi_Buffer
# symbols can be localized (below) and not collide with the NES copies.
for s in Gb_Apu Gb_Oscs Blip_Buffer Multi_Buffer gb_apu_wrapper; do
    clang++ -O3 $TARGET_FLAGS -fPIC -std=c++14 -fvisibility=hidden -DNDEBUG \
        -I"$SRC/src/libs/gb_snd_emu" \
        -c "$SRC/src/libs/gb_snd_emu/$s.cpp" -o "$OBJ/gb_$s.o"
done
# Partial-link the GB objects: ld -r converts the hidden (private-extern) symbols
# to local, the ld64 equivalent of upstream's GNU objcopy --localize-hidden. This
# is what lets GB's Blip_Buffer coexist with NES's at the final link.
ld -r "$OBJ"/gb_Gb_Apu.o "$OBJ"/gb_Gb_Oscs.o "$OBJ"/gb_Blip_Buffer.o \
      "$OBJ"/gb_Multi_Buffer.o "$OBJ"/gb_gb_apu_wrapper.o -o "$OBJ/gb_combined.o"

echo "DSP chiptune ($TARGET)"
# Plugin wrapper sees both APU headers; no filesystem access (module_dir ignored).
clang++ -O3 $TARGET_FLAGS -fPIC -std=c++14 -DNDEBUG \
    -I"$SRC/src/dsp" -I"$SRC/src/libs/nes_snd_emu" -I"$SRC/src/libs/gb_snd_emu" \
    -c "$SRC/src/dsp/chiptune_plugin.cpp" -o "$OBJ/chiptune_plugin.o"
clang++ -O2 $TARGET_FLAGS -std=c++14 -dynamiclib -undefined dynamic_lookup \
    "$OBJ/chiptune_plugin.o" "$OBJ/Nes_Apu.o" "$OBJ/Nes_Oscs.o" "$OBJ/Blip_Buffer.o" \
    "$OBJ/gb_combined.o" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true
if [ -d "$SRC/src/chain_patches" ]; then
    mkdir -p "$DEST/chain_patches"
    cp "$SRC/src/chain_patches/"* "$DEST/chain_patches/"
fi

echo "chiptune ($TARGET) staged at $(dirname "$DSP_OUT")"
