#!/bin/sh
# Kept as the POSIX entry point used by dub.sdl; the real logic is shared with
# Windows in tools/build_shims.py.
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
exec "$PY" "$ROOT/tools/build_shims.py" core
