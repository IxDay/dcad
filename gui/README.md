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

A released binary needs no such install. Windows and Linux use a self-extracting
launcher that expands the embedded GUI, icons, fonts, D sources, static libraries,
project template and OCCT/GLFW libraries into a versioned cache under the user's
data directory. The macOS `dcad.app` instead places the real GUI and the same
resources in `Contents/`, because LaunchServices terminates an app that execs
into an unsigned cache binary. The Windows launcher uses the GUI subsystem and
suppresses the child console; it redirects the GUI's stdout/stderr to `gui.log`
next to the extracted binary and reports startup failures in a message box.
Linux includes a `Terminal=false` desktop entry.

The Windows release embeds a private LDC compiler, its D imports/libraries and a
portable `lld-link`, so hot reload works with no compiler install and without
Visual Studio. A source checkout uses the `ldc2` on `PATH`; if it is missing the
error is shown in the editor instead of terminating the GUI.

The interface follows the monitor's HiDPI scale: fonts, spacing, panes and icon
sizes all multiply by the framebuffer/window ratio. Set `DCAD_UI_SCALE` (for
example `DCAD_UI_SCALE=1.5`) to override the detected scale.

The window opens the real tracked file `samples/coffee-table/table.d` and
renders it in your VS Code **Base16 Default Light** palette (`#f8f8f8` editor, `#f9f9f9` sidebar,
`#383838` text, `#7cafc2` accents). The code editor uses D-aware syntax colours
from the same theme, with D keywords and `@attribute` highlighting. The 3D
preview uses an OpenSCAD-style renderer: near-white background, soft directional
shading, and the classic RGB axis cross and ground grid. Select the surface
shader from **View > Shader** in the native menu bar: **Default** uses the VS
Code Base16 yellow (`#f7ca88`), and **Wood** reproduces the baked Lambert look
of the joinery project's GLBs. GLFW has no menu API, so each platform supplies
its own bridge: an AppKit `NSMenu` on macOS, a Win32 `HMENU` on Windows, and a
small Xlib menu bar on Linux. All three forward the selection to the renderer
through the same C callback.
Edit the script, press **Cmd/Ctrl+Enter** (or click **Run**) to recompile and
re-mesh.

The left sidebar shows the current project's directory with the exact file icons
VS Code uses (its built-in Seti icon theme, extracted to PNGs). Click a disclosure
arrow to expand or collapse folders, and click a file to load it into the editor.
The sidebar is always visible. Startup opens the bundled coffee-table sample
directly: there is no recent-project list, folder picker or "create a project?"
prompt until you choose **File > New Project...** (Cmd/Ctrl+N), which scaffolds
the three-piece daimochi-tsugi joint in a folder you choose, opens `main.d` and runs its
take-apart animation. You can also pass a project directory, `.dcad.toml` or a
`.d` file to `dcad-gui` on the command line; **Save** always writes the open file
in that directory. Each coffee-table element has its own module, which you can
open and Run to preview that element alone.
When an animated script is loaded, its parts are listed as a transparent overlay
in the top-right of the preview: hovering a part highlights it in the render, and
clicking it opens the source module that builds that part.

The code pane has two fixed tabs. **Code** is the D editor described above.
**Agent** is an in-UI OpenCode client: it runs the installed `opencode` CLI in the
open project directory with its own credentials and full tool access, attaches
the active `.d` file, and streams text, tool calls and errors into the tab. Enter
or **Send** submits a prompt; Cmd/Ctrl+Enter inserts a newline. Session IDs and
transcripts are stored only in dcad's app cache (`~/Library/Caches/dcad/agent` on
macOS, `~/.cache/dcad/agent` on Linux, `%LOCALAPPDATA%\dcad\agent` on Windows),
one per project root, so no hidden files are added to the project. dcad runs a
standalone OpenCode server with `OPENCODE_DB` pointing into that same cache;
your existing OpenCode config and credentials are unchanged.

## Controls

| Action | Input |
|---|---|
| Code / Agent tabs | Click the fixed tabs at the top of the editor pane |
| Run script | Cmd/Ctrl+Enter, or the Run icon (Code tab) |
| Send agent prompt | Enter in the Agent prompt, or Send; Cmd/Ctrl+Enter adds a newline |
| Orbit | Left-drag in the viewport |
| Pan | Middle/Right-drag in the viewport |
| Zoom | Scroll over the viewport |
| Standard view | Icon buttons: fit, iso, up, down, front/back, left/right, reset |
| Display toggles | Icon buttons with check marks: axes, grid, wireframe, orthographic |
| New project | File > New Project... (Cmd/Ctrl+N) → scaffold daimochi-tsugi |
| Save script | Save icon → writes the open script file |
| Project tree | Expand/collapse folders; click a file to open it |
| Parts list | Hover a part to highlight it; click to open its source `.d` file |
| Animate | Play/pause and restart icons, full-width timeline (click/drag to scrub), `FPS`, `Steps` (animated scripts only) |
| Shader | Native menu bar: View > Shader > Default (VS Code yellow) / Wood (joints GLB) |

The sidebar, editor and preview use a fixed 220px sidebar and a 3:2
editor-to-preview split of the remaining width: they cannot be dragged, resized
or re-docked, and none has a title header. The parts overlay appears only for
animated scripts and has no pane, border or background.
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
the default axonometric view. A new mesh or a pane resize refits the camera to the
whole bounding sphere for the current aspect ratio, so the object stays in view.
The second row toggles the axis cross, ground grid,
wireframe rendering and orthographic projection. `Deflection` controls OCCT mesh
density. The pane never scrolls: the animation controls sit above the canvas,
and the image is sized to the space that remains, so everything fits vertically.

### Animation

The animation panel follows OpenSCAD's animation window: **Animate** starts and
pauses playback, the full-width timeline fills as the cycle advances (click or
drag anywhere on it to scrub), and one cycle takes `Steps / FPS` seconds. The
overlay shows elapsed time; the normalised position (0 → 1) is passed to the
script's keyframe sampler internally.

A body-style script opts into playback with two extra locals alongside `result`;
a module-style script exposes them as `dcadParts()` / `dcadPoses()` functions:

```d
auto animParts = parts;            // .id + .shape for each moving part
auto animPoses = allPoses();       // double[3][string][] keyframes, t in [0,1]
```

The wrapper exports them over the plugin ABI. Each part is meshed **once**;
playback only uploads one translation uniform per part per frame, so the 18-part
coffee-table animation runs without any OCCT work in the render loop. Keyframes
are plain data (no delegates), so nothing outlives the script's stack frame.
See [`scripts/coffee-table-animation.d`](scripts/coffee-table-animation.d) for
the full script, and `motion.allPoses()` for the knock-down keyframes.

## Script contract

The editor holds **D source**. On Run the GUI compiles it to a shared library
with `ldc2`, loads it with `dlopen`, and calls a single exported entry point.
There are two source forms, both producing the same shape/mesh and using the
same animation overlay. The released launcher contains the `source/` modules,
sample scripts, project template and static libraries needed for this step; it
expands them into a cache directory and the GUI resolves them through
`gui.platform.resourceRoot()` rather than the process working directory.

### Body-style scripts

The editor text is inserted into a generated `dcad_script_run()` function, so it
must define a local named `result`, of type `Shape` or `Workplane`:

```d
auto model = Workplane.create()
    .box(60, 40, 20)
    .faces(FaceSelector.top)
    .circle(8)
    .cutThruAll();

Shape result = model.shape;
```

An animated script also defines `animParts` and `animPoses` locals (see
[Animation](#animation)). `scripts/default.d` and
`scripts/coffee-table-animation.d` use this form, and the wrapper imports common
kernel modules (`Shape`, `Workplane`, selectors, `std.math`, `std.array`,
`std.algorithm`, …) for it.

### Module-style scripts

A source with a `module` declaration is compiled as its own translation unit.
The host imports it and calls `dcadMain()` — or `build()` for a single element —
so there is no injected function body and no `result` local:

```d
module module_assembly;
import dcad.shape : Shape;

Shape dcadMain() { /* ... */ return shape; }

// Optional animation hooks; the keyframes may come from an imported file.
NamedPart[] dcadParts() { return tableParts(); }
double[3][string][] dcadPoses() { return allPoses(); }
```

Use functions rather than module variables for the hooks: D tries to evaluate
module-level initialisers at compile time, and OCCT calls have no CTFE source.
See [`scripts/module-assembly.d`](scripts/module-assembly.d).

### One file per element

The element files in `samples/coffee-table/` export `Shape build()` and are
always compiled into the plugin. Open `samples/coffee-table/leg.d` from the
project tree and press Run: the host displays that leg alone, with no separate
viewer script. `samples/coffee-table/table.d` imports every element plus the
motion data and exposes the full animated assembly. An assembly script imports
only the elements it needs:

```d
import parts.leg : leg = build;
Shape result = leg();
```

A compile error in either form, or a geometry exception from OCCT, is captured
and shown inline in the editor; the viewport mesh is cleared so a stale render
is never mistaken for a successful build.

### Why hot-loaded shared libraries?

This is option **(a)** from the architecture discussion: the script *is* D, with
the full language and kernel API available. The tradeoff is ~1–2 s compile time
per Run — fine for a manual keybind, too slow for per-keystroke auto-run. The
alternative, an embedded interpreter, would re-run instantly but would require
a custom parser and a restricted subset of the DSL. Both D classes and OCCT
shape pointers cross the plugin boundary safely with LDC 1.43 (verified on
macOS/ARM64: GC allocations, exceptions, and cloned `TopoDS_Shape` handles).
Dynamic loading, plugin link flags and the scratch-directory id are isolated in
`gui/source/gui/platform.d`; Windows uses `LoadLibrary`/`GetProcAddress` while
POSIX uses `dlopen`/`dlsym`.

## Architecture

```
gui/source/gui/app.d           GLFW window, ImGui frame, two panes, main loop
gui/source/gui/script_host.d   compile + dlopen + both script forms + error capture
gui/source/gui/project.d       manifest, project handler, New Project scaffolding
gui/source/gui/viewport.d      FBO render-to-texture, VBO mesh, camera, shading
gui/source/launcher/           embedded payload + self-extracting launcher
project-template/daimochi/     editable D source scaffolded by New Project
samples/coffee-table/          dimensions, util, one file per element, motion, table
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
