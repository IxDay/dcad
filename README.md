# dcad

A statically typed CAD scripting library in D that binds OpenCASCADE (OCCT)
directly through `extern(C++)`, with a CadQuery-style fluent DSL on top.

Status: **Phase 1 bindings + Phase 2 prototype are working**. The end-to-end
box → hole → fillet → STEP script runs; a loft example runs too. See
`docs/RISKS.md` for what is still provisional.

## Layout

```
source/dcad/occt/     direct extern(C++) declarations of the OCCT subset
source/dcad/dsl/      Workplane builder and typed selectors
source/dcad/shape.d   owning wrapper around TopoDS_Shape
shim/                 ~150 lines of C++ for the gaps extern(C++) cannot express
examples/             acceptance examples
samples/              standalone models (coffee-table)
gui/                  native GUI shell (editor + 3D preview)
project-template/     files created by File > New Project
docs/                 scope, risks, Phase 3 design, output formats
```

## Build

Requirements: LDC, dub, and OCCT 7.7–7.9 development headers/libraries.

```sh
dub build                      # library + C++ shim
dub run :box-hole-fillet       # writes box_hole_fillet.step
dub run :loft                  # writes loft.step
dub run :coffee-table          # writes samples/coffee-table/table/*.step
dub run :gui                   # native editor + 3D preview (needs glfw)
./tests/run.sh                 # acceptance check for all of the above

# Self-contained release binary: build :gui first, then embed it.
dub build :gui --build=release
python3 tools/relocate_macos.py  # macOS only; resolves bundled dylibs via @rpath
DCAD_EMBED_RESOURCES=1 dub build :gui-launcher --build=release
```

For a Debian/Ubuntu Linux target:

```sh
apt install ldc dub libocct-dev libocct-ocaf-dev
dub build
```

`dub.sdl` lists the OCCT libraries explicitly rather than relying on a
pkg-config file, so the same recipe works with the distro packages and with
Homebrew's OCCT. The shim build script (`tools/build_shims.py`) tries the usual
include locations; set `CXX=g++` on Linux if `clang++` is not installed, or
`DCAD_OCCT_INCLUDE` to point at a custom OCCT prefix.

### Supported targets

| Target | OCCT source | C++ ABI | CI runner |
|---|---|---|---|
| Linux x86-64 | `libocct-dev` | Itanium | `ubuntu-24.04` |
| Linux aarch64 | `libocct-dev` | Itanium | `ubuntu-24.04-arm` |
| macOS x86-64 | Homebrew `opencascade` | Itanium | `macos-15-intel` |
| macOS ARM64 | Homebrew `opencascade` | Itanium | `macos-15` |
| Windows x86-64 | official OCCT 7.9.3 binaries | Microsoft | `windows-2025` |

`.github/workflows/build.yml` builds and runs `tests/run.sh` on every target in
release mode (`DCAD_BUILD_TYPE=release`; local runs default to dub's debug
build) and publishes one asset per target: `dcad-linux-x86_64`,
`dcad-linux-aarch64`, `dcad-macos-x86_64.app.zip`, `dcad-macos-arm64.app.zip`
and `dcad-windows-x86_64.exe`. There is no tarball and no bundled README. Linux
and Windows assets are self-extracting binaries containing the real GUI, icons,
fonts, sample scripts, the D source/import libraries needed by hot reload, the
new-project template and (where available) OCCT/GLFW libraries. On first launch
they expand them into a versioned cache under the user's data directory, so a
downloaded binary works from any working directory with no system OCCT/GLFW
install. On Linux, mark the download executable after saving it
(`chmod +x dcad-<target>`). Pushing a tag publishes those assets as a GitHub
Release. While the GUI is still being validated, the release tag is the rolling
`0.1.0` marker: each update deletes the previous release and force-pushes
`0.1.0` to the validated commit instead of creating a new version.

The macOS asset is a zip containing a signed `dcad.app`; unzip it and open the
app from Finder. Every Mach-O in the bundle is ad-hoc signed; unsigned arm64
code will not run on Apple Silicon even without quarantine. A free Apple
account cannot issue a Developer ID certificate or notarize the app, so
Gatekeeper still warns on first launch. On macOS Sequoia, open the app once,
then go to System Settings → Privacy & Security and click **Open Anyway**. If
that still refuses, remove the download's quarantine attribute in Terminal:
`xattr -dr com.apple.quarantine /path/to/dcad.app`. The Windows binary is built
with the GUI subsystem and a WinMain entry point, and starts the embedded GUI
with `CREATE_NO_WINDOW`, so no console window appears; its diagnostics go to
`gui.log` in the extracted cache and fatal errors use a message box.

The Windows binary and macOS app also embed a private LDC toolchain. Windows
adds a portable COFF linker and the matching static MSVC CRT/Win32 import
libraries, so hot reload works without installing D, LDC or Visual Studio;
macOS uses its private compiler with the system linker. Source
checkouts still use the `ldc2` on `PATH`; a missing compiler is reported in the
editor rather than exiting the application. The interface follows the display's
HiDPI scale automatically; set `DCAD_UI_SCALE` to override it (for example,
`DCAD_UI_SCALE=1.5`).
On Windows the
CI downloads the official OCCT 7.9.3 `vc14-64` archive, its matching `3rdparty`
archive (for `TKernel`'s jemalloc/TBB and the media/image dependencies reached
via `TKDESTEP`), and GLFW 3.4's prebuilt WIN64 binaries. Headers, `.lib` files
and DLLs are staged under `C:\dcad\occt\{include,lib,bin}`. To reproduce
locally, use the same archives (or an OCCT 7.7–7.9 MSVC build; current vcpkg
ships 8.x, which the bindings do not target yet). Windows shims and GLFW use
the static `/MT` CRT to match LDC; use `glfw3_mt.lib`, not `glfw3.lib`.

Windows ARM64 is not supported: LDC 1.43 publishes only x86/x64 Windows
toolchains, so cross-compiling with `-mtriple=aarch64-pc-windows-msvc` cannot
link against ARM64 druntime/phobos libraries.

## Example

```d
import dcad.dsl.workplane : Workplane;
import dcad.dsl.selector : FaceSelector, EdgeSelector;

auto model = Workplane.create()
    .box(80, 60, 10)
    .faces(FaceSelector.top)
    .circle(8)
    .cutThruAll()
    .edges(EdgeSelector.vertical)
    .fillet(2);

model.exportStep("box_hole_fillet.step");
```

Selectors are enums: `.faces(">Z")` from CadQuery becomes
`.faces(FaceSelector.top)`, so a typo is a compile error.

## GUI

[`gui/`](gui/) is a native three-pane IDE-style shell with a project tree, D
script editor, and a live 3D preview whose parts list is a transparent overlay,
built on GLFW, the ImGui docking branch, raw OpenGL and `ImGuiColorTextEdit`.
Icons are extracted from VS Code's own Seti and codicon assets, and the UI uses
your VS Code Base16 Default Light palette with an OpenSCAD-style renderer. The workspace
recommends `webfreak.code-d` for D LSP support in VS Code. Scripts are D source
compiled to a hot-loaded shared library on each Run; both legacy script bodies
and module-style scripts are supported, including one runnable module per
element in `samples/coffee-table/`.

`dcad-gui` also acts as a project handler:
`dcad-gui <directory|.dcad/config.toml|file.d>` opens a plain directory of D
sources whose root is marked by `.dcad/config.toml` (legacy `.dcad.toml`,
`dcad.toml` and `dcad.json` still work, and a bare directory is promoted), and
`dcad-gui --new-project <project-directory>`
(or **File > New Project...**) scaffolds the CC BY 4.0
[daimochi-tsugi](https://ixday.github.io/carpentry/#daimochi-tsugi) joint from
`project-template/daimochi` directly into the chosen directory, which becomes
the project root, so the Explorer shows the source decomposition immediately.
The only hidden entry at the root is `.dcad/`, containing `config.toml`, an
empty `history.jsonl` and `patches/`. The generated config's `name` is the
chosen directory's name; older configs without a `name` still fall back to the
directory name. Opening or creating a project shows a modal loading bar while
the script compiles. The Agent tab stores its transcript in the same `.dcad/`
directory and keeps API credentials in `.dcad/config.toml`. See
[`gui/README.md`](gui/README.md) for controls and the execution-model tradeoff.

## Samples

[`samples/coffee-table`](samples/coffee-table/) is a port of the CadQuery
coffee-table sample: 18 mortise-and-tenon timbers exported as exact STEP files.
See [`docs/OUTPUT_FORMATS.md`](docs/OUTPUT_FORMATS.md) for which additional
export formats are cheap to add (BREP, IGES, STL, named-assembly STEP, …).
