#!/usr/bin/env python3
"""Stage one self-extracting binary per release target.

Release assets are the binaries themselves: no tarball, no README and no .app
wrapper. On first run the launcher expands the linked GUI, icons, fonts, sample
scripts, the D compiler sources/libraries and (where available) OCCT/GLFW
libraries into a versioned cache, so the downloaded file works from anywhere.

macOS binaries are ad-hoc signed by the free Apple account path. Developer ID
and notarization are not available, so Gatekeeper instructions live in the
release notes rather than in a shipped README.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sign_macos(binary):
    """Ad-hoc sign and verify the launcher after it was linked/copied."""
    codesign = shutil.which("codesign")
    if not codesign:
        raise SystemExit("codesign is required to package a macOS binary")
    quiet = dict(check=True, stdout=subprocess.DEVNULL,
                 stderr=subprocess.DEVNULL)
    subprocess.run([codesign, "--force", "--sign", "-", str(binary)], **quiet)
    subprocess.run([codesign, "--verify", "--strict", str(binary)], **quiet)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", help="e.g. dcad-macos-arm64")
    parser.add_argument("--launcher", default=None,
                        help="path to the built launcher (default: auto)")
    parser.add_argument("--out", default="dist",
                        help="directory that receives the binary")
    parser.add_argument("--version", default="0.0.0",
                        help="accepted for compatibility; raw binaries are unversioned")
    args = parser.parse_args()

    if args.launcher:
        launcher = Path(args.launcher)
    elif args.target.startswith("dcad-windows"):
        launcher = ROOT / "dcad-launcher.exe"
    else:
        launcher = ROOT / "dcad-launcher"
    if not launcher.exists():
        raise SystemExit("launcher not found: " + str(launcher))

    suffix = ".exe" if args.target.startswith("dcad-windows") else ""
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    binary = out_dir / (args.target + suffix)
    shutil.copy2(launcher, binary)
    if suffix == "":
        os.chmod(binary, 0o755)

    if args.target.startswith("dcad-macos"):
        if sys.platform != "darwin":
            raise SystemExit("macOS binaries must be signed on a macOS runner")
        sign_macos(binary)

    print("PACKAGED", binary)


if __name__ == "__main__":
    main()
