#!/bin/bash
# fetch-modules.sh - Downloads release tarballs for every catalog module and
# installs the ones that are pure JS (no compiled .so) into native/build/external.
# Native-DSP modules are listed for per-module macOS porting. Re-runnable.
set -u

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$NATIVE_DIR/../git-schwung"
OUT="$NATIVE_DIR/build/external"        # staged modules, synced by sync-runtime.sh
CACHE="$NATIVE_DIR/build/module-cache"
mkdir -p "$OUT" "$CACHE"

python3 - "$REPO_DIR/module-catalog.json" <<'EOF' > "$CACHE/modules.tsv"
import json, sys
c = json.load(open(sys.argv[1]))
dirmap = {"sound_generator": "sound_generators", "audio_fx": "audio_fx",
          "midi_fx": "midi_fx", "tool": "tools", "overtake": "tools"}
for m in c["modules"]:
    print("\t".join([m["id"], dirmap.get(m["component_type"], "tools"),
                     m["github_repo"], m.get("default_branch", "main")]))
EOF

native_list="$CACHE/native-needed.txt"
: > "$native_list"
installed=0
skipped=0

while IFS=$'\t' read -r id category repo branch; do
    dest="$OUT/$category/$id"
    if [ -d "$dest" ]; then installed=$((installed+1)); continue; fi

    rel=$(curl -sL --max-time 15 "https://raw.githubusercontent.com/$repo/$branch/release.json") || rel=""
    url=$(echo "$rel" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('download_url',''))
except Exception: print('')")
    if [ -z "$url" ]; then
        echo "  $id: no release.json, skipping"
        skipped=$((skipped+1))
        continue
    fi

    tmp=$(mktemp -d)
    if ! curl -sL --max-time 60 "$url" -o "$tmp/m.tar.gz" || ! tar xzf "$tmp/m.tar.gz" -C "$tmp" 2>/dev/null; then
        echo "  $id: download/extract failed"
        rm -rf "$tmp"
        skipped=$((skipped+1))
        continue
    fi
    rm "$tmp/m.tar.gz"

    # Module root = directory containing module.json
    mroot=$(find "$tmp" -name module.json -maxdepth 3 | head -1 | xargs dirname 2>/dev/null)
    if [ -z "$mroot" ]; then
        echo "  $id: no module.json in tarball"
        rm -rf "$tmp"
        skipped=$((skipped+1))
        continue
    fi

    if find "$mroot" -name '*.so' | grep -q .; then
        # ARM-Linux binaries — unusable here; needs a macOS port of its DSP
        echo "$id	$category	$repo" >> "$native_list"
        rm -rf "$tmp"
    else
        mkdir -p "$dest"
        cp -R "$mroot/" "$dest/"
        echo "  $id: installed (JS-only)"
        installed=$((installed+1))
        rm -rf "$tmp"
    fi
done < "$CACHE/modules.tsv"

echo
echo "JS-only modules staged in $OUT: $installed"
echo "Need native macOS ports ($(wc -l < "$native_list" | tr -d ' ')): see $native_list"
