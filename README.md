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
build) and packages a native archive per target. The released `dcad-gui` is a
**self-extracting launcher**: its executable contains the real GUI, icons,
fonts, sample scripts, the D source/import libraries needed by hot reload, the
new-project template and (where available) OCCT/GLFW libraries. On first launch
it expands them into a versioned cache under the user's data directory and runs
the GUI from there, so a downloaded binary works from any working directory
with no system OCCT/GLFW install. Pushing a tag also publishes those archives
as a GitHub Release.

The macOS archive contains `dcad.app` with the real GUI and its resources inside
`Contents/`, so Finder opens the application directly instead of Terminal. It is
signed ad hoc; first-time downloads may still need right-click > Open. The
Windows launcher is built with the GUI subsystem and a WinMain entry point, and
starts the embedded GUI with `CREATE_NO_WINDOW`, so no console window appears;
its diagnostics go to `gui.log` in the extracted cache and fatal errors use a
message box. The Linux archive includes a `Terminal=false` desktop entry for
the same behaviour.

The Windows archive also embeds a private LDC toolchain and a portable COFF
linker, so hot reload works without installing D, LDC or Visual Studio. Source
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
`dcad-gui <directory|.dcad.toml|file.d>` opens a plain directory of D sources
whose root is marked by a `.dcad.toml` file (legacy `dcad.json` still works), and
`dcad-gui --new-project <directory>`
(or **File > New Project...**) scaffolds the CC BY 4.0
[daimochi-tsugi](https://ixday.github.io/carpentry/#daimochi-tsugi) joint from
`project-template/daimochi`. See [`gui/README.md`](gui/README.md) for controls
and the execution-model tradeoff.

## Samples

[`samples/coffee-table`](samples/coffee-table/) is a port of the CadQuery
coffee-table sample: 18 mortise-and-tenon timbers exported as exact STEP files.
See [`docs/OUTPUT_FORMATS.md`](docs/OUTPUT_FORMATS.md) for which additional
export formats are cheap to add (BREP, IGES, STL, named-assembly STEP, …).
