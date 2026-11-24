#!/bin/sh
# POSIX entry point; Windows uses tools/build_shims.py directly from dub.sdl.
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
exec "$PY" "$ROOT/tools/build_shims.py" gui
