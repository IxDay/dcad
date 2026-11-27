#!/usr/bin/env python3
"""Point the macOS GUI binary's OCCT/GLFW imports at its bundled dylibs.

Run after dub links dcad-gui and before the launcher payload is built. The
launcher extracts dylibs next to the inner GUI, while the signed .app puts them
in Contents/Resources/lib, so both private rpaths are installed in that order.
Homebrew is retained only as the final fallback for `dub run :gui`; release
payloads call strip_development_rpaths() on a copy before packaging so shipped
binaries stay self-contained. Otherwise the host can bind to Homebrew OCCT while
a hot-loaded plugin uses the bundled copies, and shapes crossing that boundary
can mesh to zero triangles.
"""

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def is_bundled(name):
    base = Path(name).name
    return base.startswith("libTK") or base.startswith("libglfw")


def strip_development_rpaths(binary):
    """Remove checkout-only fallback rpaths from a binary that will be shipped.

    The source-checkout GUI keeps Homebrew as a last resort so `dub run :gui`
    works without an embedded payload. Packaged binaries must not retain those
    absolute paths: dyld could silently mix host OCCT with bundled OCCT, and
    the release would no longer be self-contained.
    """
    for rpath in sorted(existing_rpaths(binary)):
        if rpath.startswith(("/opt/homebrew", "/usr/local")):
            subprocess.run(["install_name_tool", "-delete_rpath", rpath,
                            str(binary)], check=False)
    if shutil.which("codesign"):
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)],
                       check=True)
    else:
        raise SystemExit("codesign is required to relocate the macOS GUI")


def existing_rpaths(binary):
    output = subprocess.run(["otool", "-l", str(binary)], check=True,
                            capture_output=True, text=True).stdout
    paths = set()
    for line in output.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0] == "path":
            paths.add(parts[1])
    return paths


PRIVATE_RPATHS = [
    "@executable_path/lib",
    "@executable_path/../Resources/lib",
]
# Keep Homebrew as the last resort so `dub run :gui` still works from a source
# checkout. The private paths exist in the launcher cache and in dcad.app and
# are searched first, so a packaged GUI never mixes with Homebrew OCCT.
FALLBACK_RPATHS = [
    "/opt/homebrew/lib",
    "/usr/local/lib",
]


def main():
    binary = ROOT / "dcad-gui"
    if not binary.exists():
        return
    output = subprocess.run(["otool", "-L", str(binary)], check=True,
                            capture_output=True, text=True).stdout
    for line in output.splitlines()[1:]:
        old = line.strip().split()[0]
        if not is_bundled(old):
            continue
        replacement = "@rpath/" + Path(old).name
        if old != replacement:
            subprocess.run(["install_name_tool", "-change", old, replacement,
                            str(binary)], check=True)

    present = existing_rpaths(binary)
    for rpath in sorted(present):
        if rpath.startswith("/opt/homebrew") or rpath.startswith("/usr/local") \
                or rpath in PRIVATE_RPATHS:
            subprocess.run(["install_name_tool", "-delete_rpath", rpath,
                            str(binary)], check=False)
    # -add_rpath appends, so install the launcher path before the .app path and
    # leave the checkout fallback last.
    for rpath in PRIVATE_RPATHS + FALLBACK_RPATHS:
        subprocess.run(["install_name_tool", "-add_rpath", rpath,
                        str(binary)], check=True)
    # install_name_tool invalidates any existing signature. Apple Silicon will
    # refuse to execute an unsigned GUI, so make signing failures build errors.
    if shutil.which("codesign"):
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)],
                       check=True)
    else:
        raise SystemExit("codesign is required to relocate the macOS GUI")


if __name__ == "__main__":
    main()
