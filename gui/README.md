# dcad-gui

Native three-pane GUI shell around the dcad kernel: a collapsible project tree
on the left, a D script editor in the middle, and a live OpenGL preview of the
resulting OCCT shape. For animated scripts the parts list is a borderless,
transparent overlay on the preview.

## Run

```bash
brew install glfw                     # one-time, macOS
dub run :gui
```

The window opens with a default script already loaded and rendered in your
VS Code **Base16 Default Light** palette (`#f8f8f8` editor, `#f9f9f9` sidebar,
`#383838` text, `#7cafc2` accents). The code editor uses D-aware syntax colours
from the same theme, with D keywords and `@attribute` highlighting. The 3D
preview uses an OpenSCAD-style renderer: near-white background, neutral
light-grey shaded geometry, and the classic RGB axis cross and ground grid.
Edit the script, press **Cmd/Ctrl+Enter** (or click **Run**) to recompile and
re-mesh.

The left sidebar shows the repository file tree with the exact file icons VS Code
uses (its built-in Seti icon theme, extracted to PNGs). Click a disclosure arrow
to expand or collapse folders, and click a file to load it into the editor. The
sidebar is always visible. The coffee-table sample and its animation are
available under `samples` for a quick demo; when an animated script is loaded,
its parts are listed as a transparent overlay in the top-right of the preview and
hovering a part highlights it in the render.

## Controls

| Action | Input |
|---|---|
| Run script | Cmd/Ctrl+Enter, or the Run icon |
| Orbit | Left-drag in the viewport |
| Pan | Middle/Right-drag in the viewport |
| Zoom | Scroll over the viewport |
| Standard view | Icon buttons: fit, iso, up, down, front/back, left/right, reset |
| Display toggles | Icon buttons with check marks: axes, grid, wireframe, orthographic |
| Save script | Save icon → writes the open file, or `.dcad-gui-state` |
| Project tree | Expand/collapse folders; click a file to open it |
| Parts list | Hover a part in the preview's top-right overlay to highlight it |
| Animate | Play/pause and restart icons, `Time`, `FPS`, `Steps` (animated scripts only) |

The sidebar, editor and preview use a fixed 220px / 44% / remaining split: they
cannot be dragged, resized or re-docked, and none has a title header. The parts
overlay appears only for animated scripts and has no pane, border or background.
File icons are rasterised from the light variants in VS Code's `theme-seti`
extension and UI icons from its codicon font, giving PNGs in
`gui/assets/icons/`. Regenerate them with
`swift gui/assets/extract-vscode-icons.swift`; licences are in
`gui/assets/LICENSES.md`. The UI chrome and code editor use your VS Code Base16
Default Light palette; the 3D render uses the OpenSCAD-style light renderer.
Each pane sizes its main area to the space that remains; the editor and sidebar
keep scrollbars enabled for long content, while the preview pane never scrolls.

### Preview toolbar

The viewport has an OpenSCAD-in-VS-Code style toolbar built from VS Code's own
codicon icons (rasterised to PNG), with hover tooltips.
The first row frames the model or switches to one of the six standard views plus
the default axonometric view. The second row toggles the axis cross, ground grid,
wireframe rendering and orthographic projection. `Deflection` controls OCCT mesh
density. The pane never scrolls: the animation controls sit above the canvas,
and the image is sized to the space that remains, so everything fits vertically.

### Animation

The animation panel follows OpenSCAD's animation window: **Animate** starts and
pauses playback, **Time** scrubs through the cycle in seconds, and one cycle
takes `Steps / FPS` seconds. `$t` is the normalised position (0 → 1) passed to
the script's keyframe sampler.

A script opts into playback by defining two extra locals alongside `result`:

```d
auto animParts = parts;            // .id + .shape for each moving part
auto animPoses = allPoses();       // double[3][string][] keyframes, t in [0,1]
```

The wrapper exports them over the plugin ABI. Each part is meshed **once**;
playback only uploads one translation uniform per part per frame, so the 18-part
coffee-table animation runs without any OCCT work in the render loop. Keyframes
are plain data (no delegates), so nothing outlives the script's stack frame.
See [`scripts/coffee-table-animation.d`](scripts/coffee-table-animation.d) for
the full script, and `coffee_motion.allPoses()` for the knock-down keyframes.

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
Phase 4 is partially done: script persistence is wired;
debounced auto-run is intentionally left off because the compile-per-Run model
is too slow for it.
