#!/bin/sh
# Build the GUI C++ shim (ImGui docking + backends + TextEditor + OCCT mesher).
# Incremental: only recompiles when a source or this script is newer than the archive.
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
GUI="$ROOT/gui"
OUT="$ROOT/build/libdcad_gui_shim.a"
CXX=${CXX:-clang++}

VENDOR="$GUI/vendor"
INCLUDES="-I$VENDOR -I$VENDOR/backends -I/opt/homebrew/include -I/opt/homebrew/include/opencascade -I/usr/local/include/opencascade -I/usr/include/opencascade"
DEFS="-DIMGUI_DEFINE_MATH_OPERATORS"
CXXFLAGS="-std=c++17 -O2 -fPIC $DEFS $INCLUDES"

SRCS="
$VENDOR/imgui.cpp
$VENDOR/imgui_draw.cpp
$VENDOR/imgui_tables.cpp
$VENDOR/imgui_widgets.cpp
$VENDOR/backends/imgui_impl_glfw.cpp
$VENDOR/backends/imgui_impl_opengl3.cpp
$VENDOR/TextEditor.cpp
$GUI/shim/dcad_gui_shim.cpp
"

need_build=0
if [ ! -f "$OUT" ]; then
    need_build=1
else
    for s in $SRCS "$0"; do
        if [ "$s" -nt "$OUT" ]; then need_build=1; break; fi
    done
fi

if [ "$need_build" -eq 0 ]; then
    exit 0
fi

mkdir -p "$ROOT/build"
OBJS=""
for s in $SRCS; do
    o="$ROOT/build/gui_$(basename "$s" .cpp).o"
    # Recompile object if source is newer.
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ] || [ "$0" -nt "$o" ]; then
        echo "  CXX $(basename "$s")"
        $CXX $CXXFLAGS -c "$s" -o "$o"
    fi
    OBJS="$OBJS $o"
done

ar rcs "$OUT" $OBJS
echo "  AR  $(basename "$OUT")"
