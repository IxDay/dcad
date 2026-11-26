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

from make_crt_lib import build as build_crt_lib

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


def copy_tree(source, target, skip=()):
    if not source.exists():
        return
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target, symlinks=True,
                    ignore=shutil.ignore_patterns(*skip))


def copy_file(source, target):
    if not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def stage_runtime_files(stage):
    """Keep a plain copy of the payload for the macOS .app bundle.

    LaunchServices terminates an app that execs into an unsigned binary in the
    cache, so the macOS package puts the real GUI and its resources directly in
    Contents/. The embedded ZIP still carries the same files for single-binary
    development builds and for the other platforms.
    """
    copy_tree(ROOT / "gui" / "assets", stage / "assets")
    copy_tree(ROOT / "samples", stage / "samples")
    copy_tree(ROOT / "source", stage / "source")
    copy_tree(ROOT / "gui" / "scripts", stage / "gui" / "scripts")
    copy_tree(ROOT / "project-template", stage / "project-template")
    copy_file(ROOT / "dcad-gui", stage / "dcad-gui")
    copy_file(BUILD / "libdcad_shim.a", stage / "build" / "libdcad_shim.a")
    copy_file(ROOT / "libdcad.a", stage / "libdcad.a")


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


def linux_library_roots():
    """Bounded directories to search for shared libraries.

    A recursive `/usr/lib/**` glob follows symlinked trees (notably `/lib`) and
    walks debug/build-id directories forever on some hosted runners. Every
    library we need lives either directly in a multiarch directory or in a
    directory named by LD_LIBRARY_PATH, so one level is enough.
    """
    roots = ["/usr/lib/*", "/usr/local/lib/*", "/usr/lib", "/usr/local/lib"]
    for part in os.environ.get("LD_LIBRARY_PATH", "").split(os.pathsep):
        part = part.rstrip("/")
        if part:
            roots.append(part)
    return roots


def linux_ldconfig_index():
    """Map sonames to paths from ldconfig, when available."""
    index = {}
    try:
        result = subprocess.run(["ldconfig", "-p"], check=False,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return index
    for line in result.stdout.splitlines():
        if "=>" not in line:
            continue
        fields = line.split()
        if not fields:
            continue
        soname = fields[0]
        path = line.split("=>", 1)[1].strip()
        if soname and path:
            index.setdefault(soname, path)
    return index


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
    ldconfig = linux_ldconfig_index()
    roots = linux_library_roots()
    found = []
    for name in names:
        prefix = "lib" + name + ".so"
        matches = []
        if prefix in ldconfig:
            matches.append(ldconfig[prefix])
        for soname, path in ldconfig.items():
            if soname.startswith(prefix + "."):
                matches.append(path)
        for root in roots:
            matches += glob.glob(f"{root}/{prefix}*")
        matches = [m for m in matches if Path(m).is_file()]
        if not matches:
            continue
        source = Path(matches[0]).resolve()
        versioned = lib / source.name
        shutil.copy2(source, versioned)
        found.append(versioned)
        symlink_path = lib / prefix
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


MSVC_LINK_LIBS = [
    # /MT C++ shims and D runtime objects need the static CRT, its C++ library
    # and the Win32 import libraries normally supplied by Visual Studio's LIB.
    "libcmt.lib",
    "libvcruntime.lib",
    "libucrt.lib",
    "libcpmt.lib",
    "kernel32.lib",
    "user32.lib",
    "gdi32.lib",
    "winspool.lib",
    "shell32.lib",
    "ole32.lib",
    "oleaut32.lib",
    "uuid.lib",
    "comdlg32.lib",
    "advapi32.lib",
    "oldnames.lib",
    "legacy_stdio_definitions.lib",
]


def msvc_library_dirs():
    """Directories containing the MSVC and Windows SDK linker inputs."""
    dirs = []
    vc = os.environ.get("VCToolsInstallDir") or os.environ.get("VCINSTALLDIR")
    if vc:
        dirs.append(Path(vc) / "lib" / "x64")
    kit = os.environ.get("UniversalCRTSdkDir") or os.environ.get("WindowsSdkDir")
    ucrt_version = os.environ.get("UCRTVersion")
    if kit and ucrt_version:
        dirs.append(Path(kit) / "Lib" / ucrt_version / "ucrt" / "x64")
    sdk = os.environ.get("WindowsSdkDir")
    sdk_version = os.environ.get("WindowsSDKVersion") or os.environ.get("WindowsSdkDirVersion")
    if sdk and sdk_version:
        dirs.append(Path(sdk) / "Lib" / sdk_version / "um" / "x64")
    return [p for p in dirs if p.is_dir()]


def stage_msvc_libraries(tool):
    """Copy the linker inputs a bundled Windows script needs from CI's MSVC."""
    dirs = msvc_library_dirs()
    if not dirs:
        return 0
    target = tool / "lib" / "msvc"
    target.mkdir(parents=True, exist_ok=True)
    copied = 0
    for name in MSVC_LINK_LIBS:
        for directory in dirs:
            source = directory / name
            if source.is_file():
                copy_file(source, target / name)
                copied += 1
                break
    return copied


def windows_toolchain(stage):
    """Bundle a private LDC so hot reload works without a host compiler.

    CI downloads the official LDC Windows package and a portable lld-link
    (from Rust's redistributable rust-lld). Only the files ldc2 needs to compile
    a plugin are kept: the compiler, its import libraries and D sources, a COFF
    linker, and the MSVC CRT/Win32 import libraries that lld would otherwise
    find through Visual Studio. A user's PATH and Visual Studio install are not
    involved.
    """
    roots = []
    env_root = os.environ.get("DCAD_LDC_ROOT")
    if env_root:
        roots.append(Path(env_root))
    roots += sorted(Path("C:/dcad").glob("ldc2-*"), reverse=True)
    installed = shutil.which("ldc2")
    if installed:
        roots.append(Path(installed).resolve().parent.parent)

    ldc_root = next((p for p in roots if (p / "bin" / "ldc2.exe").is_file()),
                    None)
    if ldc_root is None:
        return False

    linker = Path(os.environ.get("DCAD_LLD_LINK", ""))
    if not linker.is_file():
        installed_lld = shutil.which("lld-link")
        if installed_lld:
            linker = Path(installed_lld)
    if not linker.is_file():
        fallback = Path("C:/dcad/lld/bin/lld-link.exe")
        if fallback.is_file():
            linker = fallback
    if not linker.is_file():
        return False

    tool = stage / "toolchain"
    copy_file(ldc_root / "bin" / "ldc2.exe", tool / "bin" / "ldc2.exe")
    copy_file(linker, tool / "bin" / "lld-link.exe")
    for dll in sorted((ldc_root / "bin").glob("*.dll")):
        copy_file(dll, tool / "bin" / dll.name)
    copy_tree(ldc_root / "etc" / "ldc2.conf", tool / "etc" / "ldc2.conf")
    copy_tree(ldc_root / "import", tool / "import", skip=("*.pdb",))
    copy_tree(ldc_root / "lib", tool / "lib", skip=("*.pdb",))
    (tool / "lib" / "dcad-crt-legacy.lib").write_bytes(build_crt_lib())
    stage_msvc_libraries(tool)

    licenses = tool / "licenses"
    for base in [ldc_root] + list(linker.parents)[:8]:
        for name in ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"]:
            source = base / name
            if source.is_file():
                copy_file(source, licenses / (base.name + "-" + name))
    return (tool / "bin" / "ldc2.exe").is_file()


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    embedded = os.environ.get("DCAD_EMBED_RESOURCES") == "1"
    stage = BUILD / "resource-stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    has_libs = False
    has_compiler = False
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

            print("  STAGE platform libraries", flush=True)
            if WINDOWS:
                has_libs = windows_libraries(stage)
                print("  STAGE private D toolchain", flush=True)
                has_compiler = windows_toolchain(stage)
            elif MACOS and os.environ.get("DCAD_EMBED_SYSTEM_LIBS") != "0":
                has_libs = macos_libraries(stage)
            elif os.environ.get("DCAD_EMBED_SYSTEM_LIBS") != "0":
                has_libs = linux_libraries(stage)
            print("  STAGE platform libraries done", flush=True)

            # `stage` already mirrors the payload root (it contains lib/).
            # Prefixing another "lib/" would produce lib/lib/*.dll, which the
            # launcher does not see when it stages DLLs next to the inner GUI.
            for path in sorted(stage.rglob("*")):
                if path.is_file():
                    zf.write(path, path.relative_to(stage).as_posix())
            zf.writestr("embedded.manifest",
                        "dcad=1\nlibs=" + ("1" if has_libs else "0") +
                        "\ncompiler=" + ("1" if has_compiler else "0") + "\n")
        else:
            zf.writestr("embedded.manifest", "dcad=0\nlibs=0\n")

    # The macOS package needs the same files outside the ZIP (see
    # stage_runtime_files). Do this after the ZIP is closed so they are not
    # written twice and the launcher payload stays unchanged.
    if embedded and MACOS:
        stage_runtime_files(stage)

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
          f"({PAYLOAD.stat().st_size} bytes, libs={has_libs}, "
          f"compiler={has_compiler})", flush=True)


if __name__ == "__main__":
    main()
