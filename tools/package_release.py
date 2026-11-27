#!/usr/bin/env python3
"""Stage one release asset per target.

Linux gets the raw self-extracting binary, Windows gets the GUI-subsystem .exe,
and macOS gets a signed .app bundle zipped as a single GitHub asset. There is no
tarball and no bundled README; setup/Gatekeeper notes live in the release page.
"""

import argparse
import html
import os
import shutil
import stat
import subprocess
import sys
import zipfile
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

# Thin/fat Mach-O magics, little- and big-endian. The bundle contains the GUI,
# relocated OCCT/GLFW dylibs and the private compiler used by hot reload. Apple
# Silicon refuses to execute any unsigned arm64 Mach-O, so sign them all.
MACHO_MAGICS = (
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
)


def quiet_run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)


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
    quiet_run([codesign, "--force", "--sign", "-", str(path)])


def build_app(bundle_dir, version):
    """Copy the staged GUI/resources into a Finder-openable dcad.app."""
    app = bundle_dir / "dcad.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    for path in (macos, resources):
        path.mkdir(parents=True, exist_ok=True)

    stage = ROOT / "build" / "resource-stage"
    gui = stage / "dcad-gui"
    if not gui.exists():
        raise SystemExit("staged macOS GUI not found: " + str(gui))
    shutil.copy2(gui, macos / "dcad-gui")
    os.chmod(macos / "dcad-gui", 0o755)

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
        quiet_run([codesign, "--verify", "--strict", str(path)])
    quiet_run([codesign, "--verify", "--deep", "--strict", str(app)])
    print(f"  ad-hoc signed and verified {len(machos)} Mach-O files")
    return app


def zip_app(app, asset):
    """Zip dcad.app without adding AppleDouble files that break its seal."""
    base = app.parent
    with zipfile.ZipFile(asset, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            info = zipfile.ZipInfo(str(path.relative_to(base)))
            # A fixed timestamp keeps the asset reproducible; file modes still
            # travel in external_attr so Finder can launch MacOS/dcad-gui.
            info.date_time = (1980, 1, 1, 0, 0, 0)
            st = path.lstat()
            if path.is_symlink():
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, os.readlink(path))
            elif path.is_dir():
                info.filename += "/"
                info.external_attr = (stat.S_IFDIR | 0o755) << 16
                archive.writestr(info, b"")
            else:
                info.external_attr = (stat.S_IFREG | (st.st_mode & 0o7777)) << 16
                archive.writestr(info, path.read_bytes())


def stage_macos(target, out_dir, version):
    """Publish a signed .app as a zip; GitHub assets cannot be directories."""
    if sys.platform != "darwin":
        raise SystemExit("macOS assets must be built on a macOS runner")
    app = out_dir / "dcad.app"
    shutil.rmtree(app, ignore_errors=True)
    build_app(out_dir, version)
    asset = out_dir / (target + ".app.zip")
    zip_app(app, asset)
    shutil.rmtree(app)
    return asset


def stage_binary(target, out_dir, launcher):
    suffix = ".exe" if target.startswith("dcad-windows") else ""
    asset = out_dir / (target + suffix)
    shutil.copy2(launcher, asset)
    if not suffix:
        os.chmod(asset, 0o755)
    return asset


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", help="e.g. dcad-macos-arm64")
    parser.add_argument("--launcher", default=None,
                        help="path to the built launcher (default: auto)")
    parser.add_argument("--out", default="dist",
                        help="directory that receives the asset")
    parser.add_argument("--version", default="0.0.0",
                        help="CFBundle version for macOS; ignored elsewhere")
    args = parser.parse_args()

    if args.launcher:
        launcher = Path(args.launcher)
    elif args.target.startswith("dcad-windows"):
        launcher = ROOT / "dcad-launcher.exe"
    else:
        launcher = ROOT / "dcad-launcher"
    if not launcher.exists():
        raise SystemExit("launcher not found: " + str(launcher))

    if not args.version or not args.version[0].isdigit():
        args.version = "0.0.0"

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.target.startswith("dcad-macos"):
        asset = stage_macos(args.target, out_dir, args.version)
    else:
        asset = stage_binary(args.target, out_dir, launcher)
    print("PACKAGED", asset)


if __name__ == "__main__":
    main()
