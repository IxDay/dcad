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


# Thin/fat Mach-O magics, little- and big-endian. Signing only the GUI and a
# known dylib directory leaves the bundled compiler/tools unsigned, which macOS
# refuses to execute on Apple Silicon even after the quarantine flag is gone.
MACHO_MAGICS = (
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
)


def mach_o_files(root):
    """Return every Mach-O inside root, deepest paths first for signing."""
    found = []
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with path.open("rb") as stream:
                if stream.read(4) not in MACHO_MAGICS:
                    continue
        except OSError:
            continue
        found.append(path)
    return sorted(found, key=lambda p: len(p.parts), reverse=True)


def ad_hoc_sign(codesign, path):
    quiet = dict(check=True, stdout=subprocess.DEVNULL,
                 stderr=subprocess.DEVNULL)
    subprocess.run([codesign, "--force", "--sign", "-", str(path)], **quiet)


def package_macos(target_dir, launcher, version):
    """Build the .app around the real GUI, not the self-extracting launcher.

    LaunchServices kills an app that execs (or spawns) into the unsigned GUI in
    the runtime cache. Putting the GUI and its resources in the bundle keeps a
    single signed process, so Finder opens the application directly.
    """
    app = target_dir / "dcad.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    for path in (macos, resources):
        path.mkdir(parents=True, exist_ok=True)

    stage = ROOT / "build" / "resource-stage"
    gui = stage / "dcad-gui"
    if not gui.exists():
        raise SystemExit("staged macOS GUI not found: " + str(gui))
    copy_launcher(gui, macos / "dcad-gui")

    # Everything the GUI, a hot-loaded module or a New Project needs lives in
    # Contents/Resources, hidden from the sidebar and from Finder's app view.
    for item in sorted(stage.iterdir()):
        if item.name == "dcad-gui":
            continue
        target = resources / item.name
        if item.is_dir():
            shutil.copytree(item, target, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target)

    (contents / "Info.plist").write_text(
        PLIST.format(version=html.escape(version)), encoding="utf-8")

    # A free Apple account cannot issue Developer ID certificates or notarize,
    # so ad-hoc sign every executable in the bundle. Apple Silicon refuses to
    # run unsigned arm64 code even when the download has no quarantine flag.
    codesign = shutil.which("codesign")
    if not codesign:
        raise SystemExit("codesign is required to package dcad.app")
    machos = mach_o_files(app)
    if macos / "dcad-gui" not in machos:
        raise SystemExit("GUI binary was not detected as Mach-O")
    for path in machos:
        ad_hoc_sign(codesign, path)
    ad_hoc_sign(codesign, app)

    # Fail the pipeline rather than shipping a bundle dyld will kill at
    # dlopen/exec time. Loose compiler tools are verified individually because
    # `codesign --deep` only checks nested bundle code.
    for path in machos:
        subprocess.run([codesign, "--verify", "--strict", str(path)],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    subprocess.run([codesign, "--verify", "--deep", "--strict", str(app)],
                   check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    print(f"  ad-hoc signed and verified {len(machos)} Mach-O files")
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
