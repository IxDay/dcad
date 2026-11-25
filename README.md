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
build) and packages a native archive (release binary, GUI assets and sample
scripts) per target.
Pushing a tag also publishes those archives as a GitHub Release. On Windows the
CI downloads the official OCCT 7.9.3 `vc14-64` archive and GLFW 3.4's prebuilt
WIN64 binaries, then stages headers, `.lib` files and DLLs under
`C:\dcad\occt\{include,lib,bin}`. To reproduce locally, use the same archives
(or an OCCT 7.7–7.9 MSVC build; current vcpkg ships 8.x, which the bindings do
not target yet).

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
element in `samples/coffee-table/`. See [`gui/README.md`](gui/README.md) for controls
and the execution-model tradeoff.

## Samples

[`samples/coffee-table`](samples/coffee-table/) is a port of the CadQuery
coffee-table sample: 18 mortise-and-tenon timbers exported as exact STEP files.
See [`docs/OUTPUT_FORMATS.md`](docs/OUTPUT_FORMATS.md) for which additional
export formats are cheap to add (BREP, IGES, STL, named-assembly STEP, …).
