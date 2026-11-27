#!/bin/sh
# Verify the vendored OpenCode source pin used by the embedded D agent port.
set -eu
cd "$(dirname "$0")/.."

PIN_DIR=vendor/opencode-v2.3.2
test -f "$PIN_DIR/SOURCE_PIN.txt"
test -f "$PIN_DIR/MANIFEST.sha256"
test -f "$PIN_DIR/PORT_MAP.txt"

# Windows checkouts may use CRLF. Normalize text before matching or hashing so
# the pin stays byte-identical to the upstream source on every target.
normalized() {
    tr -d '\r' < "$1"
}

if ! normalized "$PIN_DIR/SOURCE_PIN.txt" | grep -q '^tag: v2\.3\.2$'; then
    echo "unexpected OpenCode source tag" >&2
    exit 1
fi
if ! normalized "$PIN_DIR/SOURCE_PIN.txt" | grep -q '^commit: c0ad18b402eb2827fc1ee71c171b1177b3fc02d1$'; then
    echo "unexpected OpenCode source commit" >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    HASH_CMD="sha256sum"
else
    HASH_CMD="shasum -a 256"
fi

fail=0
while IFS= read -r raw; do
    line=$(printf '%s\n' "$raw" | tr -d '\r')
    case "$line" in ''|'#'*) continue ;; esac
    expected=${line%%  *}
    path=${line#*  }
    test -f "$PIN_DIR/$path" || {
        echo "missing pinned source: $path" >&2
        fail=1
        continue
    }
    actual=$(normalized "$PIN_DIR/$path" | $HASH_CMD | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "checksum mismatch: $path" >&2
        fail=1
    fi
done < "$PIN_DIR/MANIFEST.sha256"

# Every upstream file named by the translation map must be pinned.
while IFS= read -r raw; do
    line=$(printf '%s\n' "$raw" | tr -d '\r')
    case "$line" in ''|'#'*) continue ;; esac
    paths=${line#* }
    for path in $paths; do
        test -f "$PIN_DIR/$path" || {
            echo "port map references unpinned source: $path" >&2
            fail=1
        }
        grep -Fq "  $path" "$PIN_DIR/MANIFEST.sha256" || {
            echo "port map source is not in the manifest: $path" >&2
            fail=1
        }
    done
done < "$PIN_DIR/PORT_MAP.txt"

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "PASS: OpenCode source pin v2.3.2 (c0ad18b4)"
