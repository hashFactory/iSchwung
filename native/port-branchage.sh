#!/bin/bash
# port-branchage.sh - Builds the branchage MIDI FX module (multi-random note
# generator, Grids-style) for Apple targets and stages it into build/external for
# sync-runtime.sh.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$NATIVE_DIR/../git-schwung"
SRC="$NATIVE_DIR/build/ports/branchage-src"
DEST="$NATIVE_DIR/build/external/midi_fx/branchage"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/midi_fx/branchage/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/midi_fx/branchage/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/broduoliviercontact-web/Schwung-Midi-Fx-branchages-Multi-Random-generator "$SRC"
fi

# ABI: branchage calls host->get_bpm / get_clock_status, but its bundled
# plugin_api_v1.h places those fields earlier than git-schwung's host_api_v1_t
# does — so against the stale header they'd read the wrong offsets. Overwrite the
# build clone's copy with git-schwung's (git-schwung itself is never touched).
cp "$REPO_DIR/src/host/plugin_api_v1.h" "$SRC/src/host/plugin_api_v1.h"

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP branchage ($TARGET)"
# Plugin + Grids/branches engines (separate TUs). Writes a debug log under
# /data/UserData, so the compat overrides are force-included to remap that fopen.
clang -O2 $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC/src/host" -I"$SRC/src/dsp" \
    "$SRC/src/host/branchage_plugin.c" \
    "$SRC/src/dsp/branches_engine.c" \
    "$SRC/src/dsp/grids_engine.c" \
    "$SRC/src/dsp/grids_tables.c" \
    -o "$DSP_OUT" -lm

cp "$SRC/src/module.json" "$DEST/"
cp "$SRC/src/help.json"   "$DEST/" 2>/dev/null || true

echo "branchage ($TARGET) staged at $(dirname "$DSP_OUT")"
