#!/bin/bash
# sync-runtime.sh <data-root> - Populates the directory that stands in for the
# Move's /data/UserData: schwung JS bundle, fonts, config. Idempotent.
set -e

DATA_ROOT="${1:?usage: sync-runtime.sh <data-root>}"
NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$NATIVE_DIR/../git-schwung"
S="$DATA_ROOT/schwung"

# TARGET=macos (default) or iossim — selects which dsp.so builds get installed.
TARGET="${TARGET:-macos}"
case "$TARGET" in
    macos)      B="$NATIVE_DIR/build/modules" ;;
    iossim|ios) B="$NATIVE_DIR/build/$TARGET/modules" ;;
    *) echo "unknown TARGET=$TARGET"; exit 1 ;;
esac

mkdir -p "$S"/{shadow,shared,host/fonts,bin,config,patches,slot_state,recordings} \
         "$S"/modules/{chain,store,sound_generators,audio_fx,midi_fx,tools}

cp "$REPO_DIR"/src/shadow/shadow_ui.js "$REPO_DIR"/src/shadow/*.mjs "$S/shadow/"

# Tweak: Back from the Global Settings root calls shadow_request_exit(), which
# only hides the overlay so the Move firmware shows through — there's no Move
# here, so it leaves the view stuck on Settings. Every other exit path does
# setView(SLOTS) first; add it to this one too. Anchored on the upstream comment
# (idempotent), applied to our staged copy only — git-schwung is untouched.
if ! grep -q "iSchwung: standalone home" "$S/shadow/shadow_ui.js"; then
    perl -0pi -e 's{(/\* Exit Global Settings .*? exit shadow mode \*/\n)}{$1                setView(VIEWS.SLOTS);  /* iSchwung: standalone home */\n}s' \
        "$S/shadow/shadow_ui.js"
fi
cp "$REPO_DIR"/src/shared/*.mjs "$S/shared/"
cp "$REPO_DIR"/src/host/version.txt "$S/host/" 2>/dev/null || echo "dev" > "$S/host/version.txt"
cp "$NATIVE_DIR"/build/assets/host/font.png "$NATIVE_DIR"/build/assets/host/font.png.dat "$S/host/"
cp "$NATIVE_DIR"/build/assets/host/fonts/* "$S/host/fonts/"
cp "$REPO_DIR"/assets/logo-*.png "$S/host/"

# Built-in JS module UIs (chain & store menus reference these)
for m in chain store file-browser song-mode; do
    if [ -d "$REPO_DIR/src/modules/$m" ]; then
        mkdir -p "$S/modules/$m"
        rsync -a --exclude 'dsp' "$REPO_DIR/src/modules/$m/" "$S/modules/$m/"
    fi
done

# Native DSP modules: module.json/ui from source trees + macOS-built dsp.so
install_module() { # category/id, source module dir (json/ui), built dsp.so
    local dest="$S/modules/$1"; local srcdir="$2"; local dsp="$3"
    mkdir -p "$dest"
    [ -d "$srcdir" ] && rsync -a --exclude 'dsp' --exclude '*.c' "$srcdir/" "$dest/"
    [ -f "$dsp" ] && cp "$dsp" "$dest/dsp.so"
    # chain_host loads in-chain audio FX as "<id>.so" (module.json "dsp" name)
    case "$1" in audio_fx/*) [ -f "$dsp" ] && cp "$dsp" "$dest/${1##*/}.so" ;; esac
}

install_module chain                          "$REPO_DIR/src/modules/chain"                  "$B/chain/dsp.so"
install_module audio_fx/freeverb              "$REPO_DIR/src/modules/audio_fx/freeverb"      "$B/audio_fx/freeverb/dsp.so"
install_module midi_fx/chord                  "$REPO_DIR/src/modules/midi_fx/chord"          "$B/midi_fx/chord/dsp.so"
install_module midi_fx/arp                    "$REPO_DIR/src/modules/midi_fx/arp"            "$B/midi_fx/arp/dsp.so"
install_module midi_fx/velocity_scale         "$REPO_DIR/src/modules/midi_fx/velocity_scale" "$B/midi_fx/velocity_scale/dsp.so"
install_module sound_generators/linein        "$REPO_DIR/src/modules/sound_generators/linein" "$B/sound_generators/linein/dsp.so"
install_module tools/wav-player               "$REPO_DIR/src/modules/tools/wav-player"       "$B/tools/wav-player/dsp.so"
install_module sound_generators/simple-synth  "$NATIVE_DIR/modules/simple-synth"             "$B/sound_generators/simple-synth/dsp.so"

# External modules staged by fetch-modules.sh / port-sf2.sh (JS-only catalog
# modules + natively ported ones like sf2 incl. its soundfont)
if [ -d "$NATIVE_DIR/build/external" ]; then
    rsync -a --exclude '*.dSYM' "$NATIVE_DIR/build/external/" "$S/modules/"
fi
# Target-specific dylib overlay (e.g. iossim sf2 build replaces the macOS one)
if [ "$TARGET" != macos ] && [ -d "$NATIVE_DIR/build/$TARGET/external" ]; then
    rsync -a --exclude '*.dSYM' "$NATIVE_DIR/build/$TARGET/external/" "$S/modules/"
fi

ln -sf /usr/bin/curl "$S/bin/curl"

if [ ! -f "$S/config/features.json" ]; then
    cat > "$S/config/features.json" <<'EOF'
{
  "shadow_ui_enabled": true,
  "link_audio_enabled": false,
  "display_mirror_enabled": false,
  "ext_midi_remap_enabled": true,
  "shadow_ui_trigger": "both"
}
EOF
fi

# Unified debug log on by default during development
touch "$S/debug_log_on"

echo "Runtime root ready at $DATA_ROOT"
