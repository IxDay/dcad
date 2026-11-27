#!/bin/sh
# Replace the macOS dcad.app with the current rolling release and launch it.
#
# Defaults to ~/Downloads/dcad.app and the arm64/x86_64 asset matching this
# Mac. Override DCAD_APP_PATH, DCAD_RELEASE_TAG or DCAD_ZIP if needed. Any
# arguments after the script are forwarded to dcad (for example a project
# directory). Set DCAD_NO_OPEN=1 to install without launching.
set -eu

case "$(uname -s)" in
    Darwin) ;;
    *)
        echo "this installer only supports macOS" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    arm64)  ASSET="dcad-macos-arm64.app.zip" ;;
    x86_64) ASSET="dcad-macos-x86_64.app.zip" ;;
    *)
        echo "unsupported macOS architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

for tool in curl unzip xattr; do
    command -v "$tool" >/dev/null || {
        echo "required command not found: $tool" >&2
        exit 1
    }
done

REPO=${DCAD_REPO:-IxDay/dcad}
TAG=${DCAD_RELEASE_TAG:-0.1.0}
APP_PATH=${DCAD_APP_PATH:-$HOME/Downloads/dcad.app}
ZIP_PATH=${DCAD_ZIP:-}
NO_OPEN=${DCAD_NO_OPEN:-0}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dcad-install.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$ZIP_PATH" ]; then
    echo "Using local archive: $ZIP_PATH"
    ZIP="$ZIP_PATH"
else
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
    echo "Downloading $URL"
    ZIP="$WORK/$ASSET"
    curl --fail --location --retry 3 --silent --show-error \
         --output "$ZIP" "$URL"
fi

UNPACKED="$WORK/unpacked"
mkdir -p "$UNPACKED"
unzip -q "$ZIP" -d "$UNPACKED"

NEW_APP="$UNPACKED/dcad.app"
if [ ! -x "$NEW_APP/Contents/MacOS/dcad-gui" ]; then
    echo "archive did not contain dcad.app" >&2
    exit 1
fi

# Unzip can create AppleDouble files that break the bundle's code signature.
find "$UNPACKED" -name '._*' -delete

# Unquarantine before replacing the old app so LaunchServices never sees a
# quarantined bundle at its final path.
xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true

if [ -e "$APP_PATH" ]; then
    echo "Removing old app: $APP_PATH"
    rm -rf "$APP_PATH"
fi
mkdir -p "$(dirname "$APP_PATH")"
mv "$NEW_APP" "$APP_PATH"
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
echo "Installed: $APP_PATH"

if [ "$NO_OPEN" = "1" ]; then
    echo "DCAD_NO_OPEN=1; skipping launch"
else
    if [ "$#" -gt 0 ]; then
        echo "Launching with: $*"
        open -n "$APP_PATH" --args "$@"
    else
        echo "Launching dcad"
        open -n "$APP_PATH"
    fi
fi
