#!/usr/bin/env python3
"""Point the macOS GUI binary's OCCT/GLFW imports at its bundled dylibs.

Run after dub links dcad-gui and before the launcher payload is built. The
launcher extracts those dylibs into <cache>/lib next to the GUI, so the inner
binary resolves them through @executable_path/lib. A Homebrew rpath is kept as
a fallback for locally built binaries.
"""

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def is_bundled(name):
    base = Path(name).name
    return base.startswith("libTK") or base.startswith("libglfw")


def existing_rpaths(binary):
    output = subprocess.run(["otool", "-l", str(binary)], check=True,
                            capture_output=True, text=True).stdout
    paths = set()
    for line in output.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and parts[0] == "path":
            paths.add(parts[1])
    return paths


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
    for rpath in ["@executable_path/lib", "/opt/homebrew/lib",
                  "/usr/local/lib"]:
        if rpath not in present:
            subprocess.run(["install_name_tool", "-add_rpath", rpath,
                            str(binary)], check=False)
    # install_name_tool invalidates any existing signature. Apple Silicon will
    # refuse to execute an unsigned GUI, so make signing failures build errors.
    if shutil.which("codesign"):
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)],
                       check=True)
    else:
        raise SystemExit("codesign is required to relocate the macOS GUI")


if __name__ == "__main__":
    main()
