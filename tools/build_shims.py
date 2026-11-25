#!/usr/bin/env python3
"""Build dcad's C++ shims on macOS, Linux and Windows.

Dub calls this for both the core OCCT shim and the GUI shim. Keeping the
compiler invocation in one script avoids three near-identical shell/batch
files and lets CI use whatever OCCT prefix it installed (DCAD_OCCT_INCLUDE).
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
GUI = ROOT / "gui"
WINDOWS = sys.platform == "win32"
MACOS = sys.platform == "darwin"


def env_paths(name):
    return [p for p in os.environ.get(name, "").split(os.pathsep) if p]


def occt_includes():
    paths = env_paths("DCAD_OCCT_INCLUDE")
    if WINDOWS:
        candidates = ["C:/dcad/occt/include/opencascade",
                      "C:/dcad/occt/include"]
    elif MACOS:
        candidates = ["/opt/homebrew/include/opencascade",
                      "/usr/local/include/opencascade",
                      "/opt/homebrew/include", "/usr/local/include"]
    else:
        candidates = ["/usr/include/opencascade",
                      "/usr/local/include/opencascade"]
    for root in env_paths("OCCT_ROOT"):
        candidates += [str(Path(root) / "include" / "opencascade"),
                       str(Path(root) / "include")]
    for path in candidates:
        if Path(path).is_dir() and path not in paths:
            paths.append(path)
    return paths


def compiler():
    override = os.environ.get("CXX")
    if override:
        return override.split()
    if WINDOWS:
        return ["cl"]
    return ["clang++"] if shutil.which("clang++") else ["g++"]


def compile_flags():
    if WINDOWS:
        # LDC links the static MSVC CRT by default; all shim objects must use
        # the same /MT runtime as the D objects and the glfw3_mt.lib archive.
        return ["/nologo", "/std:c++17", "/O2", "/EHsc", "/MT", "/W3",
                "/DNOMINMAX", "/D_CRT_SECURE_NO_WARNINGS"]
    return ["-std=c++17", "-O2", "-fPIC"]


def menu_source():
    if WINDOWS:
        return GUI / "shim" / "dcad_native_menu_win.cpp"
    if MACOS:
        return GUI / "shim" / "dcad_native_menu.mm"
    return GUI / "shim" / "dcad_native_menu_x11.cpp"


def build(which):
    if which == "core":
        sources = [ROOT / "shim" / "dcad_shim.cpp"]
        includes = occt_includes()
        prefix = ""
        out = BUILD / ("dcad_shim.lib" if WINDOWS else "libdcad_shim.a")
    elif which == "gui":
        vendor = GUI / "vendor"
        sources = [
            vendor / "imgui.cpp",
            vendor / "imgui_draw.cpp",
            vendor / "imgui_tables.cpp",
            vendor / "imgui_widgets.cpp",
            vendor / "backends" / "imgui_impl_glfw.cpp",
            vendor / "backends" / "imgui_impl_opengl3.cpp",
            vendor / "TextEditor.cpp",
            GUI / "shim" / "dcad_gui_shim.cpp",
            menu_source(),
        ]
        includes = [str(vendor), str(vendor / "backends")] + occt_includes()
        if WINDOWS:
            includes += ["C:/dcad/occt/include"]
        prefix = "gui_"
        out = BUILD / ("dcad_gui_shim.lib" if WINDOWS
                       else "libdcad_gui_shim.a")
    else:
        raise SystemExit("usage: build_shims.py core|gui")

    BUILD.mkdir(parents=True, exist_ok=True)
    cc = compiler()
    flags = compile_flags()
    defs = [] if WINDOWS else ["-DIMGUI_DEFINE_MATH_OPERATORS"]
    inc_flags = (["/I" + p for p in includes] if WINDOWS
                 else ["-I" + p for p in includes])

    objects = []
    for src in sources:
        stem = prefix + src.stem
        obj = BUILD / (stem + (".obj" if WINDOWS else ".o"))
        objects.append(obj)
        stale = (not obj.exists() or src.stat().st_mtime > obj.stat().st_mtime
                 or Path(__file__).stat().st_mtime > obj.stat().st_mtime)
        if not stale:
            continue
        print("  CXX", src.name, flush=True)
        if WINDOWS:
            cmd = cc + flags + inc_flags + defs + ["/c", str(src),
                                                   "/Fo" + str(obj)]
        else:
            cmd = cc + flags + inc_flags + defs + ["-c", str(src),
                                                   "-o", str(obj)]
        subprocess.run(cmd, check=True)

    if (out.exists()
            and all(o.exists() and o.stat().st_mtime <= out.stat().st_mtime
                    for o in objects)):
        return
    print("  AR ", out.name, flush=True)
    if WINDOWS:
        subprocess.run(["lib", "/nologo", "/OUT:" + str(out)]
                       + [str(o) for o in objects], check=True)
    else:
        subprocess.run(["ar", "rcs", str(out)]
                       + [str(o) for o in objects], check=True)


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else "core")
