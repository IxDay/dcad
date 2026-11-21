#!/bin/sh
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
mkdir -p "$ROOT/build"
CXX=${CXX:-clang++}
INCLUDES="-I/opt/homebrew/include/opencascade -I/usr/local/include/opencascade -I/usr/include/opencascade"
$CXX -std=c++17 -O2 -fPIC -c "$ROOT/shim/dcad_shim.cpp" $INCLUDES \
    -o "$ROOT/build/dcad_shim.o"
ar rcs "$ROOT/build/libdcad_shim.a" "$ROOT/build/dcad_shim.o"
