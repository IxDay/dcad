#!/bin/sh
# Acceptance check for the kernel, examples, coffee-table sample and GUI build.
set -eu
cd "$(dirname "$0")/.."

dub build --force >/dev/null
dub run :simple-box >/dev/null
dub run :box-hole-fillet >/dev/null
dub run :loft >/dev/null
dub run :coffee-table >/dev/null
dub build :gui >/dev/null
dub run :script-host-smoke >/dev/null

for f in simple_box.step box_hole_fillet.step loft.step coffee-table.step; do
    test -s "$f"
    grep -q 'ISO-10303-21' "$f"
done

test "$(ls table/*.step | wc -l | tr -d ' ')" = 18
grep -q '"tracks"' table/animation.json

echo "PASS: bindings, examples, 18-part coffee table, GUI build and script forms"
