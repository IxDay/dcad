#!/usr/bin/env python3
"""Build the launcher's embedded runtime payload.

Local development builds get an empty payload, so `dub run :gui` still reads
the checkout. CI sets DCAD_EMBED_RESOURCES=1; the resulting ZIP is linked into
dcad-launcher and contains the real GUI plus every dcad-owned file it or a
hot-loaded script needs: icons, fonts, samples, D sources, static libraries and
the daimochi project template. Platform system libraries are included when
available.
"""

import glob
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
PAYLOAD = BUILD / "dcad_payload.bin"
WINDOWS = sys.platform == "win32"
MACOS = sys.platform == "darwin"


def add_tree(zf, source, prefix):
    """Store files from a directory tree under `prefix`.

    Dotfiles are included: `.dcad.toml` is the project-root marker. Hidden
    directories remain excluded so build caches never enter the payload.
    """
    if not source.exists():
        return
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        parts = path.relative_to(source).parts
        if any(p.startswith(".") for p in parts[:-1]):
            continue
        zf.write(path, prefix + "/" + "/".join(parts))


def add_file(zf, path, name):
    if Path(path).exists():
        zf.write(path, name)


def macos_libraries(stage):
    """Stage and relocate Homebrew OCCT/GLFW dylibs for an rpath-based payload."""
    lib = stage / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    patterns = [
        "/opt/homebrew/opt/opencascade/lib/libTK*.dylib",
        "/usr/local/opt/opencascade/lib/libTK*.dylib",
        "/opt/homebrew/opt/glfw/lib/libglfw*.dylib",
        "/usr/local/opt/glfw/lib/libglfw*.dylib",
    ]
    copied = []
    for pattern in patterns:
        for source in glob.glob(pattern):
            real = Path(source).resolve()
            if real.name in [p.name for p in copied]:
                continue
            target = lib / real.name
            shutil.copy2(real, target)
            copied.append(target)

    if not copied:
        return False

    for path in copied:
        subprocess.run(["install_name_tool", "-id", "@rpath/" + path.name,
                        str(path)], check=True)
        output = subprocess.run(["otool", "-L", str(path)], check=True,
                                capture_output=True, text=True).stdout
        for line in output.splitlines()[1:]:
            old = line.strip().split()[0]
            if "opencascade" not in old and "glfw" not in old and "/lib/libTK" not in old:
                continue
            replacement = "@rpath/" + Path(old).name
            if old != replacement:
                subprocess.run(["install_name_tool", "-change", old,
                                replacement, str(path)], check=True)

    # Short names are what `ldc2 -lTKernel` looks for; the versioned files
    # stay too, for dyld's install names.
    for path in list(copied):
        stem = path.name.split(".")
        if len(stem) >= 2 and path.name.startswith("libTK"):
            short = stem[0] + ".dylib"
            if short != path.name:
                shutil.copy2(path, lib / short)
        if path.name.startswith("libglfw."):
            shutil.copy2(path, lib / "libglfw.dylib")

    (BUILD / "dcad_dylibs.txt").write_text(
        "\n".join(p.name for p in copied) + "\n")
    return True


def linux_libraries(stage):
    """Best-effort copy of the OCCT/GLFW runtime used by this build."""
    lib = stage / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    names = [
        "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKGeomAlgo",
        "TKBRep", "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKFillet",
        "TKOffset", "TKXSBase", "TKMesh", "TKSTEP", "TKSTEPBase",
        "TKSTEPAttr", "TKSTEP209", "TKXDESTEP", "TKXDEIGES", "glfw",
    ]
    found = []
    for name in names:
        matches = []
        for root in ["/usr/lib", "/lib", "/usr/local/lib"]:
            matches += glob.glob(f"{root}/**/lib{name}.so*", recursive=True)
        matches = [m for m in matches if Path(m).is_file()]
        if not matches:
            continue
        source = Path(matches[0]).resolve()
        versioned = lib / source.name
        shutil.copy2(source, versioned)
        found.append(versioned)
        symlink_path = lib / f"lib{name}.so"
        if symlink_path != versioned:
            shutil.copy2(source, symlink_path)
    return bool(found)


def windows_libraries(stage):
    lib = stage / "lib"
    occt_bin = Path("C:/dcad/occt/bin")
    occt_lib = Path("C:/dcad/occt/lib")
    if not occt_bin.is_dir():
        return False
    lib.mkdir(parents=True, exist_ok=True)
    for pattern, target in [("*.dll", occt_bin), ("*.lib", occt_lib)]:
        for path in target.glob(pattern):
            shutil.copy2(path, lib / path.name)
    return any(lib.glob("*.dll"))


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    embedded = os.environ.get("DCAD_EMBED_RESOURCES") == "1"
    stage = BUILD / "resource-stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    has_libs = False
    with zipfile.ZipFile(PAYLOAD, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        if embedded:
            # The shim resolves icons/fonts as <root>/assets/..., while the
            # source checkout keeps them under gui/assets.
            add_tree(zf, ROOT / "gui" / "assets", "assets")
            add_tree(zf, ROOT / "samples", "samples")
            add_tree(zf, ROOT / "source", "source")
            add_tree(zf, ROOT / "gui" / "scripts", "gui/scripts")
            add_tree(zf, ROOT / "project-template", "project-template")
            # The real GUI is started from the extracted cache directory, so
            # it must be part of the launcher's own payload.
            gui_exe = ROOT / ("dcad-gui.exe" if WINDOWS else "dcad-gui")
            if not gui_exe.exists():
                raise SystemExit("build the GUI binary before the launcher payload")
            add_file(zf, gui_exe,
                     "dcad-gui.exe" if WINDOWS else "dcad-gui")
            add_file(zf, BUILD / ("dcad_shim.lib" if WINDOWS else "libdcad_shim.a"),
                     "build/" + ("dcad_shim.lib" if WINDOWS else "libdcad_shim.a"))
            add_file(zf, ROOT / ("dcad.lib" if WINDOWS else "libdcad.a"),
                     "dcad.lib" if WINDOWS else "libdcad.a")

            if WINDOWS:
                has_libs = windows_libraries(stage)
            elif MACOS and os.environ.get("DCAD_EMBED_SYSTEM_LIBS") != "0":
                has_libs = macos_libraries(stage)
            elif os.environ.get("DCAD_EMBED_SYSTEM_LIBS") != "0":
                has_libs = linux_libraries(stage)

            for path in sorted(stage.rglob("*")):
                if path.is_file():
                    zf.write(path, "lib/" + path.relative_to(stage).as_posix())
            zf.writestr("embedded.manifest",
                        "dcad=1\nlibs=" + ("1" if has_libs else "0") + "\n")
        else:
            zf.writestr("embedded.manifest", "dcad=0\nlibs=0\n")

    if WINDOWS:
        rc = BUILD / "dcad_resources.rc"
        rc.write_text('1 RCDATA "' + PAYLOAD.name + '"\n')
        rc_tool = shutil.which("llvm-rc") or shutil.which("rc")
        if rc_tool is None:
            raise SystemExit("no Windows resource compiler (llvm-rc or rc) found")
        subprocess.run([rc_tool, "/FO", str(BUILD / "dcad_resources.res"),
                        str(rc)], cwd=BUILD, check=True)
    elif MACOS:
        # Apple's ld has no GNU `-b binary`; assemble an .incbin instead.
        asm = BUILD / "dcad_resources.s"
        asm.write_text(
            '.section __TEXT,__dcadpayload,regular\n'
            '.globl _binary_dcad_payload_bin_start\n'
            '_binary_dcad_payload_bin_start:\n'
            '.incbin "' + PAYLOAD.name + '"\n'
            '.globl _binary_dcad_payload_bin_end\n'
            '_binary_dcad_payload_bin_end:\n')
        subprocess.run(["cc", "-c", asm.name, "-o", "dcad_resources.o"],
                       cwd=BUILD, check=True)
    else:
        subprocess.run(["ld", "-r", "-b", "binary", "-o",
                        "dcad_resources.o", PAYLOAD.name],
                       cwd=BUILD, check=True)

    print("  ZIP ", PAYLOAD.relative_to(ROOT),
          f"({PAYLOAD.stat().st_size} bytes, libs={has_libs})", flush=True)


if __name__ == "__main__":
    main()
