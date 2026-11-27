#!/bin/sh
# Acceptance check for the kernel, examples, coffee-table sample and GUI build.
set -eu
cd "$(dirname "$0")/.."

# CI publishes release binaries; local runs default to dub's debug build.
BUILD_TYPE=${DCAD_BUILD_TYPE:-debug}
BUILD_FLAG="--build=$BUILD_TYPE"

./tools/check_opencode_pin.sh

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
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            # Git Bash's `test -x` can resolve .exe suffixes, but exec does not
            # reliably; always name the Windows executable explicitly.
            DCAD_PRINT_ROOT_FILE="$ROOT_FILE" ./dcad-launcher.exe --print-root >/dev/null 2>&1
            ;;
        *)
            DCAD_PRINT_ROOT_FILE="$ROOT_FILE" ./dcad-launcher --print-root >/dev/null 2>&1
            ;;
    esac
    test -f "$ROOT_FILE" || {
        echo "launcher did not write its cache root" >&2
        exit 1
    }
    ROOT=$(cat "$ROOT_FILE")
    test -f "$ROOT/dcad-gui" || test -f "$ROOT/dcad-gui.exe"
    test -f "$ROOT/project-template/daimochi/.dcad.toml"
    test -f "$ROOT/libdcad.a" || test -f "$ROOT/dcad.lib"
    test -d "$ROOT/assets/icons"
    test -s "$ROOT/assets/icons/refresh.png"
    test -s "$ROOT/assets/MesloLGS_NF_Regular.ttf"
    test -f "$ROOT/samples/coffee-table/table.d"
    test -d "$ROOT/samples/coffee-table"
    test -d "$ROOT/source"

    # A cache marked current but missing its assets must repair itself. This
    # covers interrupted extractions and stale caches from earlier builds.
    rm -f "$ROOT/assets/icons/refresh.png"
    rm -f "$ROOT_FILE"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            DCAD_PRINT_ROOT_FILE="$ROOT_FILE" ./dcad-launcher.exe --print-root >/dev/null 2>&1
            ;;
        *)
            DCAD_PRINT_ROOT_FILE="$ROOT_FILE" ./dcad-launcher --print-root >/dev/null 2>&1
            ;;
    esac
    test -s "$ROOT/assets/icons/refresh.png" || {
        echo "launcher did not repair an incomplete cache" >&2
        exit 1
    }
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            test -x "$ROOT/toolchain/bin/ldc2.exe"
            test -x "$ROOT/toolchain/bin/lld-link.exe"
            test -f "$ROOT/toolchain/lib/phobos2-ldc.lib"
            test -f "$ROOT/toolchain/lib/dcad-crt-legacy.lib"
            test -f "$ROOT/toolchain/lib/msvc/libcmt.lib"
            test -f "$ROOT/toolchain/lib/msvc/libcpmt.lib"
            test -f "$ROOT/toolchain/lib/msvc/libucrt.lib"
            test -f "$ROOT/toolchain/lib/msvc/kernel32.lib"
            test -f "$ROOT/toolchain/lib/msvc/legacy_stdio_wide_specifiers.lib"
            test -f "$ROOT/toolchain/lib/mingw/msvcrt.lib"
            SMOKE_BIN=./dcad-script-host-smoke.exe
            ;;
        *)
            SMOKE_BIN=./dcad-script-host-smoke
            if [ "$(uname -s)" = Darwin ]; then
                test -x "$ROOT/toolchain/bin/ldc2"
                test -f "$ROOT/toolchain/etc/ldc2.conf/30-compiler.conf"
                test -f "$ROOT/toolchain/import/object.d"
                test -f "$ROOT/toolchain/lib/libphobos2-ldc.a"
                test -f "$ROOT/toolchain/lib/libdruntime-ldc.a"
            fi
            ;;
    esac

    # The shipped plugins must load without recompiling. The same smoke binary
    # still verifies ordinary compilation through the bundled Windows compiler
    # with no Visual Studio LIB/INCLUDE environment. PATH is left intact so
    # OCCT's DLLs remain findable.
    (
        unset LIB INCLUDE
        DCAD_SCRIPT_HOST_ROOT="$ROOT" DCAD_CHECK_PRECOMPILED=1 "$SMOKE_BIN"
    )

    # Start the embedded GUI once without creating a window. This catches a
    # launcher that cannot spawn its child even when --print-root succeeds.
    SMOKE_FILE="$PWD/build/gui-smoke.txt"
    rm -f "$SMOKE_FILE"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            DCAD_SMOKE_FILE="$SMOKE_FILE" ./dcad-launcher.exe >/dev/null 2>&1
            ;;
        *)
            DCAD_SMOKE_FILE="$SMOKE_FILE" ./dcad-launcher >/dev/null 2>&1
            ;;
    esac
    test -f "$SMOKE_FILE" || {
        echo "embedded GUI did not start" >&2
        exit 1
    }

    echo "PASS: embedded launcher payload, project template and GUI startup"
fi

echo "PASS: bindings, examples, 18-part coffee table, GUI, script forms, new project and embedded-agent core"
