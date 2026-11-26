#!/bin/sh
# Acceptance check for the kernel, examples, coffee-table sample and GUI build.
set -eu
cd "$(dirname "$0")/.."

# CI publishes release binaries; local runs default to dub's debug build.
BUILD_TYPE=${DCAD_BUILD_TYPE:-debug}
BUILD_FLAG="--build=$BUILD_TYPE"

dub build "$BUILD_FLAG" --force
dub run :simple-box "$BUILD_FLAG"
dub run :box-hole-fillet "$BUILD_FLAG"
dub run :loft "$BUILD_FLAG"
dub run :coffee-table "$BUILD_FLAG"
dub build :gui "$BUILD_FLAG"
dub run :script-host-smoke "$BUILD_FLAG"

for f in simple_box.step box_hole_fillet.step loft.step coffee-table.step; do
    test -s "$f"
    grep -q 'ISO-10303-21' "$f"
done

test "$(ls table/*.step | wc -l | tr -d ' ')" = 18
grep -q '"tracks"' table/animation.json

# Release builds also produce the self-extracting binary that ships to users.
# It embeds the linked GUI, the project template, the D SDK and (where the
# platform provides them) OCCT/GLFW libraries.
if [ "${DCAD_EMBED_RESOURCES:-0}" = "1" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        # Point the already-linked inner GUI at the dylibs unpacked beside it.
        python3 tools/relocate_macos.py
    fi
    dub build :gui-launcher "$BUILD_FLAG"
    python3 tools/check_payload.py build/dcad_payload.bin

    # GUI-subsystem launchers have no console to print to, so ask them to write
    # the cache root to a file instead. The same mechanism works everywhere.
    ROOT_FILE="$PWD/build/launcher-root.txt"
    rm -f "$ROOT_FILE"
    if [ -x ./dcad-launcher ]; then
        DCAD_PRINT_ROOT_FILE="$ROOT_FILE" ./dcad-launcher --print-root >/dev/null 2>&1
    else
        DCAD_PRINT_ROOT_FILE="$ROOT_FILE" ./dcad-launcher.exe --print-root >/dev/null 2>&1
    fi
    ROOT=$(cat "$ROOT_FILE")
    test -f "$ROOT/dcad-gui" || test -f "$ROOT/dcad-gui.exe"
    test -f "$ROOT/project-template/daimochi/.dcad.toml"
    test -f "$ROOT/libdcad.a" || test -f "$ROOT/dcad.lib"
    test -d "$ROOT/assets/icons"
    test -f "$ROOT/samples/coffee-table/table.d"
    test -d "$ROOT/samples/coffee-table"
    test -d "$ROOT/source"
    echo "PASS: embedded launcher payload and project template"
fi

echo "PASS: bindings, examples, 18-part coffee table, GUI, script forms and new project"
