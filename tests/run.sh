#!/bin/sh
# Acceptance check for the kernel, examples, coffee-table sample and GUI build.
set -eu
cd "$(dirname "$0")/.."

# CI publishes release binaries; local runs default to dub's debug build.
BUILD_TYPE=${DCAD_BUILD_TYPE:-debug}
BUILD_FLAG="--build=$BUILD_TYPE"

dub build "$BUILD_FLAG" --force >/dev/null
dub run :simple-box "$BUILD_FLAG" >/dev/null
dub run :box-hole-fillet "$BUILD_FLAG" >/dev/null
dub run :loft "$BUILD_FLAG" >/dev/null
dub run :coffee-table "$BUILD_FLAG" >/dev/null
dub build :gui "$BUILD_FLAG" >/dev/null
dub run :script-host-smoke "$BUILD_FLAG" >/dev/null

for f in simple_box.step box_hole_fillet.step loft.step coffee-table.step; do
    test -s "$f"
    grep -q 'ISO-10303-21' "$f"
done

test "$(ls table/*.step | wc -l | tr -d ' ')" = 18
grep -q '"tracks"' table/animation.json

echo "PASS: bindings, examples, 18-part coffee table, GUI build and script forms"
