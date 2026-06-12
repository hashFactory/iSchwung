#!/bin/bash
# port-davebox.sh - Builds the schwung-davebox "tool" module (dAVEBOx, an 8-track
# MIDI sequencer) for Apple targets and stages it into build/external for
# sync-runtime.sh. Unlike the single-file FX ports this one also bundles a
# multi-file JS UI and ships a metronome sample + Ableton-export helpers.
set -e

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$NATIVE_DIR/../git-schwung"
SRC="$NATIVE_DIR/build/ports/davebox-src"
DEST="$NATIVE_DIR/build/external/tools/davebox"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# TARGET=macos (default), iossim, or ios. Non-macos builds only swap the dylib —
# module.json/ui.js/asset staging stays shared in build/external.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)  TARGET_FLAGS="-arch arm64"; DSP_OUT="$DEST/dsp.so" ;;
    iossim) SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0-simulator -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/iossim/external/tools/davebox/dsp.so" ;;
    ios)    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
            TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot $SDK"
            DSP_OUT="$NATIVE_DIR/build/ios/external/tools/davebox/dsp.so" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/legsmechanical/schwung-davebox "$SRC"
fi

# ABI: davebox ships its own (older) copy of the host plugin header, but the host
# that loads it is git-schwung's chain_host, whose host_api_v1_t adds a
# slot_recv_channel pointer mid-struct. Compiling against the stale copy would
# mismatch every field after it → garbage calls. Overwrite the build clone's copy
# with git-schwung's (a strict superset); git-schwung itself is never touched.
cp "$REPO_DIR/src/host/plugin_api_v1.h" "$SRC/dsp/host/plugin_api_v1.h"

mkdir -p "$DEST" "$(dirname "$DSP_OUT")"

echo "DSP davebox ($TARGET)"
# Single TU (seq8.c #includes seq8_set_param.c). Hardcoded /data/UserData paths
# and the open()'d click sample are remapped by the force-included overrides.
# -I"$SRC" mirrors upstream -I.; the "host/..." include resolves source-dir-first.
clang -O3 -ffast-math $TARGET_FLAGS -dynamiclib -undefined dynamic_lookup -DNDEBUG \
    -fomit-frame-pointer \
    -include "$NATIVE_DIR/apple_compat_overrides.h" \
    -I"$SRC" \
    "$SRC/dsp/seq8.c" \
    -o "$DSP_OUT" -lm

# Shared (target-independent) staging: bundled UI, module.json, export helpers,
# and the metronome click. Cheap, so done every run rather than guarded on macos.
echo "Bundling UI + assets"
( cd "$SRC" && python3 scripts/bundle_ui.py >/dev/null && cp dist/davebox/ui.js "$DEST/ui.js" )
cp "$SRC/module.json"            "$DEST/"
cp "$SRC/export/pack.py"         "$DEST/pack.py"          2>/dev/null || true
cp "$SRC/export/ableton-master.json" "$DEST/ableton-master.json" 2>/dev/null || true

# Metronome click: source is 24-bit/stereo/44100; the DSP's render_block wants
# 16-bit/mono/48000. Mirrors scripts/build.sh, but resamples in pure Python so it
# survives Python 3.13+ dropping the audioop module.
python3 - "$SRC/assets/db-click.wav" "$DEST/click-seq8.wav" <<'PYEOF'
import sys, wave, struct
src, dst = sys.argv[1], sys.argv[2]
with wave.open(src, 'rb') as r:
    rate, nch, sw, nf = r.getframerate(), r.getnchannels(), r.getsampwidth(), r.getnframes()
    raw = r.readframes(nf)
# Mix to 16-bit mono at source rate (24-bit → 16 via >>8, average channels).
samples = []
step = sw * nch
for i in range(0, len(raw), step):
    acc = []
    for ch in range(nch):
        b = raw[i + ch*sw : i + ch*sw + sw]
        if len(b) < sw: continue
        if sw == 3:   v = struct.unpack('<i', b + (b'\xff' if b[2] & 0x80 else b'\x00'))[0] >> 8
        elif sw == 2: v = struct.unpack('<h', b)[0]
        else:         v = 0
        acc.append(v)
    if acc: samples.append(max(-32768, min(32767, sum(acc) // len(acc))))
# Normalize to full scale.
peak = max((abs(s) for s in samples), default=1) or 1
samples = [max(-32768, min(32767, round(s * 32767 / peak))) for s in samples]
# Linear-interpolate resample to 48000 Hz.
dst_rate = 48000
out_n = int(len(samples) * dst_rate / rate) if rate else 0
out = []
for j in range(out_n):
    pos = j * rate / dst_rate
    i0 = int(pos); frac = pos - i0
    a = samples[i0] if i0 < len(samples) else 0
    b = samples[i0 + 1] if i0 + 1 < len(samples) else a
    out.append(int(round(a + (b - a) * frac)))
with wave.open(dst, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(dst_rate)
    w.writeframes(struct.pack('<' + 'h' * len(out), *out))
print(f"click-seq8.wav: {len(out)} frames @ {dst_rate} Hz, 16-bit mono")
PYEOF

echo "davebox ($TARGET) staged at $(dirname "$DSP_OUT")"
