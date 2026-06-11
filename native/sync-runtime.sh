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

# Tweak: in the chain overview the knob row is unmapped (knobs map to params only
# once a component is entered), so touching a knob shows "not mapped". Wrap
# buildKnobContextForKnob to fall back to the sound generator's own default knobs
# (its ui_hierarchy), so touch/turn act on the synth — matching the labels the app
# shows. A performance-macro mapping still wins. Appended to the staged copy only.
if ! grep -q "iSchwung: overview knob fallback" "$S/shadow/shadow_ui.js"; then
cat >> "$S/shadow/shadow_ui.js" <<'ISCHWUNG_KNOBS'

/* iSchwung: overview knob fallback — map the otherwise-unmapped chain-overview
 * knob row to the slot's sound generator default knobs. */
(function () {
    if (typeof buildKnobContextForKnob !== "function") return;
    var __orig = buildKnobContextForKnob;
    buildKnobContextForKnob = function (knobIndex) {
        var ctx = __orig(knobIndex);
        if (ctx) return ctx;
        try {
            var slot = (typeof selectedSlot === "number") ? selectedSlot : -1;
            if (slot < 0) return null;
            /* A performance macro owns this knob → leave it to the existing path. */
            if (getSlotParam(slot, "knob_" + (knobIndex + 1) + "_name")) return null;
            var mod = getSlotParam(slot, "synth_module") || "";
            if (!mod) return null;
            var h = getComponentHierarchy(slot, "synth");
            var lvl = (h && h.levels) ? (h.levels.root || h.levels[Object.keys(h.levels)[0]]) : null;
            if (lvl && (!lvl.knobs || !lvl.knobs.length) && lvl.children && h.levels[lvl.children])
                lvl = h.levels[lvl.children];
            if (!lvl || !lvl.knobs || knobIndex >= lvl.knobs.length) return null;
            var key = lvl.knobs[knobIndex];
            var cps = getComponentChainParams(slot, "synth") || [];
            var meta = normalizeExpandedParamMeta(key, cps.find(function (p) { return p.key === key; }));
            var name = (meta && meta.name) ? meta.name : key.replace(/_/g, " ");
            var pn = getSlotParam(slot, "synth:name") || mod;
            return { slot: slot, key: key, fullKey: "synth:" + key, meta: meta,
                     pluginName: pn, displayName: name,
                     title: "S" + (slot + 1) + ": " + pn + " " + name };
        } catch (e) { return null; }
    };
})();
ISCHWUNG_KNOBS
fi

# Tweak: the app's on-screen knob row needs to mirror what the 8 hardware knobs
# actually control in the *current* view (component/level), not a static guess.
# getKnobContext already resolves that (it's what the OLED touch overlay uses), so
# publish the 8-knob context map to a file the app polls. Written on display flush,
# only when the mapping changes (cheap); the app fills in live values itself.
if ! grep -q "iSchwung: publish knob context" "$S/shadow/shadow_ui.js"; then
cat >> "$S/shadow/shadow_ui.js" <<'ISCHWUNG_PUBLISH'

/* iSchwung: publish knob context — mirror the live 8-knob mapping to a file.
 * Wraps globalThis.tick (a JS-writable per-frame hook; the native flush fns are
 * read-only). Reads getKnobContext (cached — cheap, no per-frame IPC) at ~3 Hz
 * and writes only when the mapping changes. The cache is dropped at ~0.7 Hz so a
 * synth loaded without a view change still refreshes; navigation already busts
 * it. The app fills in live values itself. */
(function () {
    if (typeof globalThis.tick !== "function" || typeof getKnobContext !== "function") return;
    var __tick = globalThis.tick;
    var __last = "", __cnt = 0;
    function __publishKnobs() {
        var arr = [];
        for (var k = 0; k < 8; k++) {
            var c = null;
            try { c = getKnobContext(k); } catch (e) {}
            if (c && c.fullKey && !c.noMapping && !c.noModule) {
                var m = c.meta || {};
                arr.push({ s: (c.slot != null ? c.slot : 0), k: c.fullKey,
                           n: (c.displayName || ""), t: (m.type || "float"),
                           mn: (m.min != null ? m.min : 0), mx: (m.max != null ? m.max : 1),
                           o: (m.options && m.options.length) ? m.options : [] });
            } else {
                arr.push({ s: 0, k: "", n: "", t: "", mn: 0, mx: 1, o: [] });
            }
        }
        var j = JSON.stringify(arr);
        if (j !== __last) { __last = j; try { host_write_file("/data/UserData/schwung/.ischwung_knobs.json", j); } catch (e) {} }
    }
    globalThis.tick = function () {
        var r = __tick.apply(this, arguments);
        __cnt++;
        if ((__cnt % 64) === 0) {   /* ~0.7 Hz: bust the cache so a no-nav load refreshes */
            try { if (typeof cachedKnobContexts !== "undefined") cachedKnobContexts.length = 0; } catch (e) {}
        }
        if ((__cnt % 16) === 0) __publishKnobs();   /* ~3 Hz, cached → ~no IPC */
        return r;
    };
})();
ISCHWUNG_PUBLISH
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
