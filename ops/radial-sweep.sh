#!/bin/zsh
# radial-sweep.sh - exhaustive standalone check of the launcher's geometry.
#
# There is no simulator on the laptop that ships these builds, and a
# simulator screenshot could not make this claim anyway: the fan opens
# wherever a thumb lands, so "the tile you are pointing at is the tile you
# get" has to hold for every press on every screen. This compiles the pure
# geometry out of RadialTileMenu.swift - the two structs and nothing else,
# sliced live from the file so it can never drift from what ships - and
# sweeps millions of press/touch pairs through it.
#
# What the XCTest suite covers is PLACEMENT: where the bubbles are drawn.
# What this adds is SELECTION: which index `index(at:)` hands back. That is
# the half that was never asserted, and it is where the nudged-fan bug lived
# - angle measured from `origin`, reach from `anchor`, so on any fan the
# solver had to nudge, the two frames disagreed and the wrong tile came out.
#
#   ops/radial-sweep.sh          # every layer, full grid
#
# Exit 0 = every assertion held. Exit 1 = counts printed, first failures
# quoted.
set -euo pipefail

HERE="${0:A:h}"
SRC="$HERE/../app/ATARU/Features/Home/RadialTileMenu.swift"
[ -f "$SRC" ] || { echo "missing $SRC"; exit 1 }

WORK="$(mktemp -d /tmp/ataru-radial-sweep.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# The live tile count, read off the enum rather than copied out of it: a
# sweep that hardcodes 17 stops testing the shipping fan the day a tile is
# added, which is exactly when it is most wanted.
TILES=$(awk '
  /^enum HomeTile/ { inside = 1; next }
  inside && /^}/    { exit }
  inside && /^    case / {
    sub(/^    case /, "")
    n = split($0, parts, ",")
    total += n
  }
  END { print total }
' "$SRC")
[ "$TILES" -gt 0 ] || { echo "could not read HomeTile's case count"; exit 1 }

{
  echo "import Foundation"
  echo "#if canImport(CoreGraphics)"
  echo "import CoreGraphics"
  echo "#endif"
  # Everything between the layout marker and the view marker: RadialArc and
  # RadialFan, which is the whole of the geometry and none of the SwiftUI.
  awk '/^\/\/ MARK: - Layout/ { take = 1 } /^\/\/ MARK: - View/ { take = 0 } take' "$SRC"
  echo "let liveTileCount = $TILES"
  cat "$HERE/radial-sweep.swift"
} > "$WORK/sweep.swift"

swiftc -O -o "$WORK/sweep" "$WORK/sweep.swift"
"$WORK/sweep"
