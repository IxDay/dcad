# dcad-gui

Native two-pane GUI shell around the dcad kernel: a D script editor on the
left, a live OpenGL preview of the resulting OCCT shape on the right.

## Run

```bash
brew install glfw                     # one-time, macOS
dub run :gui
```

The window opens with a default script already loaded and rendered, in a light
theme adapted from [brocanth-ui](https://github.com/DHHwasRight/brocanth-ui)
(purple `#625afa` brand, cool greys, tight radii, 32px controls). Edit the
script, press **Cmd/Ctrl+Enter** (or click **Run**) to recompile and re-mesh.

## Controls

| Action | Input |
|---|---|
| Run script | Cmd/Ctrl+Enter, or `Run` button |
| Orbit | Left-drag in the viewport |
| Pan | Middle/Right-drag in the viewport |
| Zoom | Scroll over the viewport |
| Reset camera | `Reset camera` button |
| Export STEP | `Export STEP` button → writes `dcad-export.step` |
| Save script | `Save script` button → writes `.dcad-gui-state` |

The two panes use a fixed 44% / 56% split: they cannot be dragged, resized or
re-docked. Both the UI chrome and the 3D render use the light brocanth palette.

## Script contract

The editor holds **D source**. The GUI wraps it in a generated module and
compiles it to a shared library with `ldc2`, then loads it with `dlopen`. The
script must define a local variable named `result`, of type `Shape` or
`Workplane`:

```d
auto model = Workplane.create()
    .box(60, 40, 20)
    .faces(FaceSelector.top)
    .circle(8)
    .cutThruAll();

Shape result = model.shape;
```

Common kernel modules (`Shape`, `Workplane`, selectors, `std.math`, `std.array`,
`std.algorithm`, …) are imported by the wrapper. A compile error in the script
or a geometry exception from OCCT is captured and shown inline in the editor;
the viewport mesh is cleared so a stale render is never mistaken for a
successful build.

### Why hot-loaded shared libraries?

This is option **(a)** from the architecture discussion: the script *is* D, with
the full language and kernel API available. The tradeoff is ~1–2 s compile time
per Run — fine for a manual keybind, too slow for per-keystroke auto-run. The
alternative, an embedded interpreter, would re-run instantly but would require
a custom parser and a restricted subset of the DSL. Both D classes and OCCT
shape pointers cross the plugin boundary safely on macOS/ARM64 with LDC 1.43
(verified: GC allocations, exceptions, and cloned `TopoDS_Shape` handles).

## Architecture

```
gui/source/gui/app.d           GLFW window, ImGui frame, two panes, main loop
gui/source/gui/script_host.d   compile + dlopen + error capture (script execution)
gui/source/gui/viewport.d      FBO render-to-texture, VBO mesh, camera, shading
gui/source/gui/imgui.d         extern(C) declarations for the C++ shim
gui/shim/dcad_gui_shim.cpp     ImGui + backends + TextEditor + OCCT mesher wrappers
gui/vendor/                    vendored ImGui (docking) + ImGuiColorTextEdit
gui/tools/build-gui-shim.sh    incremental build of the C++ shim archive
```

The C++ shim is needed because ImGui/TextEditor are C++ APIs (like OCCT). It
exposes a flat `extern "C"` surface and also contains the OCCT
`BRepMesh_IncrementalMesh` → triangle extraction (OCCT 7.9's
`Poly_Triangulation::Node`/`Triangle` API). Raw OpenGL is called from D via
`bindbc-opengl`; windowing via `bindbc-glfw` (static configuration).

## Status

Phases 1–3 are working end to end (shell + kernel wiring + camera/shading).
Phase 4 is partially done: script persistence and STEP export are wired;
debounced auto-run is intentionally left off because the compile-per-Run model
is too slow for it.
