#!/usr/bin/env python3
"""Assemble the per-target release payload directory.

macOS ships a .app bundle so Finder opens the GUI directly instead of Terminal.
Windows relies on the launcher's GUI subsystem (WinMain). Linux ships the raw
executable plus a desktop entry with Terminal=false.
"""

import argparse
import html
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>dcad</string>
  <key>CFBundleExecutable</key>
  <string>dcad-gui</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.ixday.dcad</string>
  <key>CFBundleName</key>
  <string>dcad</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>{version}</string>
  <key>CFBundleVersion</key>
  <string>{version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
"""

DESKTOP = """[Desktop Entry]
Type=Application
Name=dcad
Comment=D/OCCT CAD scripting editor
Exec=/bin/sh -c 'exec "$(dirname "$0")/dcad-gui" "$@"' %k %F
TryExec=dcad-gui
Terminal=false
Categories=Development;Graphics;
"""


def copy_launcher(source, target):
    shutil.copy2(source, target)
    os.chmod(target, 0o755)


def package_macos(target_dir, launcher, version):
    app = target_dir / "dcad.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    for path in (macos, resources):
        path.mkdir(parents=True, exist_ok=True)

    copy_launcher(launcher, macos / "dcad-gui")
    (contents / "Info.plist").write_text(
        PLIST.format(version=html.escape(version)), encoding="utf-8")

    # Ad-hoc signing avoids an invalid signature after copying the binary;
    # Gatekeeper may still ask first-time users to right-click and Open.
    codesign = shutil.which("codesign")
    if codesign:
        subprocess.run([codesign, "--force", "--deep", "--sign", "-", str(app)],
                       check=False)
    return macos / "dcad-gui"


def package_windows(target_dir, launcher):
    exe = target_dir / "dcad-gui.exe"
    shutil.copy2(launcher, exe)
    return exe


def package_linux(target_dir, launcher):
    binary = target_dir / "dcad-gui"
    copy_launcher(launcher, binary)
    (target_dir / "dcad.desktop").write_text(DESKTOP, encoding="utf-8")
    return binary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", help="e.g. dcad-macos-arm64")
    parser.add_argument("--launcher", default=None,
                        help="path to the built launcher (default: auto)")
    parser.add_argument("--out", default="payload",
                        help="directory that receives the target folder")
    parser.add_argument("--version", default="0.0.0")
    args = parser.parse_args()

    if args.launcher:
        launcher = Path(args.launcher)
    elif args.target.startswith("dcad-windows"):
        launcher = ROOT / "dcad-launcher.exe"
    else:
        launcher = ROOT / "dcad-launcher"
    if not launcher.exists():
        raise SystemExit("launcher not found: " + str(launcher))

    # Branch builds pass a ref name such as "main"; only tags are valid
    # CFBundle versions, so fall back to a neutral value for CI artifacts.
    if not args.version or not args.version[0].isdigit():
        args.version = "0.0.0"

    target_dir = Path(args.out) / args.target
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True)
    shutil.copy2(ROOT / "README.md", target_dir / "README.md")

    if args.target.startswith("dcad-macos"):
        packaged = package_macos(target_dir, launcher, args.version)
    elif args.target.startswith("dcad-windows"):
        packaged = package_windows(target_dir, launcher)
    else:
        packaged = package_linux(target_dir, launcher)

    print("PACKAGED", packaged.relative_to(Path(args.out)))


if __name__ == "__main__":
    main()
