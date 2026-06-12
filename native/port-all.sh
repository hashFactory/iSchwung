#!/bin/bash
# port-all.sh - Build every ported module (every port-*.sh) for all Apple targets,
# then stage BOTH runtime roots: the simulator data root and the device runtime
# tree the Xcode "Embed Schwung Runtime" phase bundles. Run this after adding or
# changing any port so the simulator AND a physical-device build both pick the
# modules up — syncing only one is the easy way to "not see new modules" on the
# other.
#
#   ./port-all.sh            # all targets, both runtimes
#   ./port-all.sh iossim     # only the simulator slice + its data root
#   ./port-all.sh ios        # only the device slice + its runtime tree
set -u

NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$NATIVE_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TARGETS="${1:-macos iossim ios}"
failed=""

for t in $TARGETS; do
    for s in port-*.sh; do
        [ "$s" = port-all.sh ] && continue
        echo "== $s ($t) =="
        if ! TARGET="$t" ./"$s"; then
            echo "!! FAILED: $s ($t)"
            failed="$failed $s($t)"
        fi
    done
done

# Stage the runtime roots for whichever targets were built.
case " $TARGETS " in *" iossim "*) TARGET=iossim ./sync-runtime.sh "$NATIVE_DIR/build/ios-data" ;; esac
case " $TARGETS " in *" ios "*)    TARGET=ios    ./sync-runtime.sh "$NATIVE_DIR/build/ios-runtime" ;; esac
# macOS prepares its own data root from build/external on launch — nothing to stage.

echo
if [ -n "$failed" ]; then
    echo "Done with FAILURES:$failed"
    exit 1
fi
echo "All modules built + staged (sim: build/ios-data, device: build/ios-runtime)."
echo "Rebuild the app in Xcode so the device runtime is re-embedded."
