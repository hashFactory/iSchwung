#!/bin/bash
# setup.sh — one-shot bootstrap for a fresh clone.
#
#   git clone https://github.com/hashFactory/iSchwung && cd iSchwung
#   ./setup.sh                 # macOS + iOS Simulator
#
# Clones the upstream Schwung repo (the app builds its UI + DSP from it, kept
# unmodified), builds the native core, and preps the simulator data root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHWUNG_URL="https://github.com/charlesvestal/schwung"
# Known-good upstream commit this port is built/tested against. Bump when you
# re-verify against a newer Schwung; leave empty to track main (riskier).
SCHWUNG_PIN="47eb0e14"

# 1. Xcode (not the bare Command Line Tools — its SDK lookup fails for xcrun).
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif ! xcode-select -p 2>/dev/null | grep -q Xcode.app; then
    echo "error: full Xcode required. Install it, then:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi
command -v python3 >/dev/null || { echo "error: python3 required (for font generation)"; exit 1; }

# 2. Upstream Schwung checkout at git-schwung/ (gitignored; kept pristine).
if [ ! -d "$ROOT/git-schwung/.git" ]; then
    echo "Cloning Schwung → git-schwung/ ..."
    git clone "$SCHWUNG_URL" "$ROOT/git-schwung"
fi
if [ -n "$SCHWUNG_PIN" ]; then
    git -C "$ROOT/git-schwung" fetch --quiet origin "$SCHWUNG_PIN" 2>/dev/null || true
    git -C "$ROOT/git-schwung" checkout --quiet "$SCHWUNG_PIN" \
        || echo "warning: couldn't pin Schwung to $SCHWUNG_PIN; using current checkout"
fi

# 3. Native core + module DSP + fonts (macOS), then the iOS-Simulator flavor.
echo "Building native core (macOS) ..."
( cd "$ROOT/native" && ./build-core.sh )

if [ "${1:-}" != "--macos-only" ]; then
    echo "Building native core (iOS Simulator) + sim data root ..."
    ( cd "$ROOT/native" && TARGET=iossim ./build-core.sh )
    ( cd "$ROOT/native" && TARGET=iossim ./sync-runtime.sh "$ROOT/native/build/ios-data" )
fi

cat <<EOF

Done. Open iSchwung.xcodeproj in Xcode and Run:
  • My Mac                 — the app prepares its own data root on launch.
  • an iOS Simulator       — already prepped above.

For a physical iPhone, see README.md (needs your own signing team + an extra
runtime-embed step).
EOF
