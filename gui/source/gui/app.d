/**
 * dcad-gui -- two-pane editor + live 3D preview.
 *
 * Left pane: ImGuiColorTextEdit holding a D script.
 * Right pane: OpenGL framebuffer texture showing the resulting OCCT shape.
 * Run with Ctrl+Enter (Cmd+Enter on macOS) or the Run button.
 */
module gui.app;

import std.stdio : stderr, writeln;
import std.file : mkdirRecurse, exists, readText, write, dirEntries, SpanMode, isDir;
import std.path : buildPath, baseName, extension;
import std.string : toStringz, format, startsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;

import bindbc.glfw;
import bindbc.opengl;

import gui.imgui;
import gui.viewport : Viewport;
import gui.script_host : ScriptHost, RunResult;

import dcad.shape : Shape;

private enum string defaultScript = q{// dcad script -- must end with `result` (a Shape or Workplane).
auto model = Workplane.create()
    .box(60, 40, 20)
    .faces(FaceSelector.top)
    .circle(8)
    .cutThruAll();

Shape result = model.shape;
};

private enum string stateFile = ".dcad-gui-state";
private enum float sidebarWidth = 220f;
private enum float partsOverlayWidth = 170f;
private enum float iconSize = 18f;

// Icon textures rasterised from VS Code's own assets: the `theme-seti`
// extension's light file icons and codicons for folders/toolbar. See
// gui/assets/extract-vscode-icons.swift and LICENSES.md.
private enum iconFolder      = "folder";
private enum iconFolderOpen  = "folder-open";
private enum iconCube        = "iso";
private enum iconFit         = "fit";
private enum iconUp          = "up";
private enum iconDown        = "down";
private enum iconFront       = "front";
private enum iconBack        = "back";
private enum iconRight       = "right";
private enum iconLeft        = "left";
private enum iconRefresh     = "refresh";
private enum iconCrosshair   = "axes";
private enum iconGrid        = "grid";
private enum iconWire        = "wire";
private enum iconSquare      = "ortho";
private enum iconCheck       = "check";
private enum iconPlay        = "play";
private enum iconPause       = "pause";
private enum iconRestart     = "restart";
private enum iconSave        = "save";

private struct FileIcon { string texture; }

private enum iconFileD         = FileIcon("file-d");
private enum iconFileJson      = FileIcon("file-json");
private enum iconFileMarkdown  = FileIcon("file-markdown");
private enum iconFileText      = FileIcon("file");
private enum iconFileShell     = FileIcon("file-shell");
private enum iconFileConfig    = FileIcon("file-config");

private void*[string] iconCache;

private void* iconTexture(string name)
{
    if (auto cached = name in iconCache)
        return *cached;
    void* tex = dcad_gui_icon(name.toStringz);
    iconCache[name] = tex;
    return tex;
}

private struct FileEntry
{
    string name;
    string path;
    bool isDir;
}

private FileIcon fileIcon(string name)
{
    switch (extension(name))
    {
        case ".d":
        case ".di":
            return iconFileD;
        case ".json":
            return iconFileJson;
        case ".sdl":
            return iconFileConfig;
        case ".md":
        case ".markdown":
            return iconFileMarkdown;
        case ".sh":
            return iconFileShell;
        default:
            return iconFileText;
    }
}

void main(string[] args)
{
    // --- GLFW / OpenGL ----------------------------------------------------
    if (glfwInit() != GLFW_TRUE)
    {
        stderr.writeln("failed to initialise GLFW");
        return;
    }
    scope(exit) glfwTerminate();

    // macOS needs a compatibility profile for GL 2.1 shaders (GLSL 120).
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 2);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
    auto window = glfwCreateWindow(1440, 900, "dcad - editor + preview",
                                   null, null);
    if (window is null)
    {
        stderr.writeln("failed to create GLFW window");
        return;
    }
    scope(exit) glfwDestroyWindow(window);
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    const glSupport = loadOpenGL();
    if (glSupport == GLSupport.noLibrary || glSupport == GLSupport.badLibrary)
    {
        stderr.writeln("failed to load OpenGL: ", glSupport);
        return;
    }

    // --- ImGui ------------------------------------------------------------
    dcad_gui_init(cast(void*) window, "#version 120");
    scope(exit) dcad_gui_shutdown();
    dcad_gui_apply_light_theme(); // Visual Studio Code Light+

    // --- Application state ------------------------------------------------
    auto editor = dcad_textedit_new();
    scope(exit) dcad_textedit_free(editor);
    dcad_textedit_set_light_palette(editor);

    immutable workDir = buildPath(".dcad-gui-scripts");
    mkdirRecurse(workDir);
    scope(exit) { /* keep generated scripts out of the repo via gitignore */ }

    immutable root = repoRoot();
    auto host = new ScriptHost(workDir, root);
    auto viewport = new Viewport();
    scope(exit) viewport.dispose(); // context is still current at scope exit

    // Restore last script (Phase 4 persistence, trivial here).
    if (exists(stateFile))
    {
        auto saved = readText(stateFile);
        if (saved.length)
            dcad_textedit_set_text(editor, saved.toStringz);
    }
    if (!exists(stateFile))
        dcad_textedit_set_text(editor, defaultScript.toStringz);

    string status = "Ready - press Ctrl+Enter (Cmd+Enter) or Run";
    string lastError;
    bool showError;
    float deflection = 1.0f;
    Shape currentShape;

    // Project tree state.
    string currentFile;
    bool[string] folderOpen = [
        "source": true,
        "gui": true,
        "gui/source": true,
        "samples": true,
        "samples/coffee-table": true,
        "tests": true,
        "tools": true,
    ];

    void drawFileTree(string absDir, string relDir)
    {
        FileEntry[] entries;
        foreach (entry; dirEntries(absDir, SpanMode.shallow))
        {
            auto name = baseName(entry.name);
            if (name.startsWith(".") || name == "build" || name == "vendor" ||
                name == "node_modules") continue;
            if (!entry.isDir && extension(name).length == 0) continue;
            entries ~= FileEntry(name, entry.name, entry.isDir);
        }
        sort!((a, b) => a.isDir != b.isDir ? a.isDir : a.name < b.name)(entries);

        foreach (e; entries)
        {
            immutable key = relDir.length ? relDir ~ "/" ~ e.name : e.name;
            if (e.isDir)
            {
                int open = ((key in folderOpen) !is null && folderOpen[key]) ? 1 : 0;
                dcad_gui_icon_image(
                    iconTexture(open != 0 ? iconFolderOpen : iconFolder), 16, 16);
                dcad_gui_same_line();
                if (dcad_gui_tree_node(e.name.toStringz, &open) != 0)
                {
                    folderOpen[key] = true;
                    drawFileTree(e.path, key);
                    dcad_gui_tree_pop();
                }
                else
                    folderOpen[key] = false;
            }
            else
            {
                int selected = key == currentFile ? 1 : 0;
                auto fi = fileIcon(e.name);
                dcad_gui_icon_image(iconTexture(fi.texture), 16, 16);
                dcad_gui_same_line();
                if (dcad_gui_selectable(e.name.toStringz, selected) != 0)
                {
                    try
                    {
                        dcad_textedit_set_text(editor, readText(e.path).toStringz);
                        currentFile = key;
                        status = "Opened " ~ key;
                    }
                    catch (Exception)
                    {
                        status = "Cannot open " ~ key;
                    }
                }
            }
        }
    }

    /// Compact VS Code icon button with a hover tooltip.
    bool iconButton(string icon, string tip)
    {
        immutable pressed = dcad_gui_icon_button(
            ("##" ~ icon).toStringz, iconTexture(icon), iconSize) != 0;
        dcad_gui_set_item_tooltip(tip.toStringz);
        return pressed;
    }

    bool toggleIconButton(string icon, string tip, bool active)
    {
        immutable pressed = dcad_gui_toggle_icon_button(
            ("##" ~ icon).toStringz, iconTexture(icon), iconTexture(iconCheck),
            iconSize, active ? 1 : 0) != 0;
        dcad_gui_set_item_tooltip(tip.toStringz);
        return pressed;
    }

    // Animation state. Parts are meshed once; each frame only updates a
    // per-part translation uniform, so playback is independent of OCCT.
    bool hasAnimation;
    bool animPlaying;
    double animTime;              // seconds into the current cycle
    float animFps = 10.0f;        // OpenSCAD-style animation settings
    int animSteps = 100;
    double lastFrameTime = glfwGetTime();

    /// One full cycle takes `steps / fps` seconds, as in OpenSCAD.
    double cycleSeconds()
    {
        return animSteps > 0 && animFps > 0
            ? cast(double) animSteps / animFps : 1.0;
    }

    void doRunScript()
    {
        import std.string : fromStringz;
        auto src = fromStringz(dcad_textedit_get_text(editor)).idup;
        auto result = host.run(src);
        if (result.ok())
        {
            currentShape = result.shape;
            hasAnimation = host.hasAnimation;
            immutable count = host.animPartCount();
            if (hasAnimation)
            {
                const(void)*[] ptrs;
                foreach (i; 0 .. count)
                {
                    auto p = host.animPartShape(i);
                    if (p !is null) ptrs ~= p;
                }
                immutable tris = viewport.setParts(ptrs, deflection);
                animTime = 0;
                animPlaying = true;
                status = "OK - " ~ count.to!string ~ " parts, " ~
                         tris.to!string ~ " triangles (animated)";
            }
            else
            {
                immutable tris = viewport.setShape(
                    cast(const(void)*)&currentShape.native(), deflection);
                status = "OK - " ~ tris.to!string ~ " triangles";
            }
            lastError = null;
            showError = false;
        }
        else
        {
            viewport.clearMesh();
            hasAnimation = false;
            animPlaying = false;
            lastError = result.error;
            showError = true;
            status = "Script failed - see error below";
            stderr.writeln("script error: ", result.error);
        }
    }

    // Initial run so the viewport is not empty on startup.
    doRunScript();

    // --- Main loop --------------------------------------------------------
    while (glfwWindowShouldClose(window) == 0)
    {
        glfwPollEvents();
        dcad_gui_new_frame();

        // Fixed layout rebuilt every frame: project tree / editor / preview.
        // Nothing can be dragged, resized or re-docked. The parts list is an
        // overlay inside the preview, not a fourth pane.
        float vw, vh;
        dcad_gui_get_viewport_size(&vw, &vh);
        immutable editorW = (vw - sidebarWidth) * 0.44f;
        immutable viewportW = vw - sidebarWidth - editorW;
        int hoveredPart = -1;

        // Run trigger: global key chord, or the editor's Run button.
        bool doRun = dcad_gui_key_chord_pressed(modCtrl | keyEnter) != 0;
        auto displayName = currentFile.length ? baseName(currentFile) : "untitled";
        if (displayName.length > 20)
            displayName = displayName[0 .. 17] ~ "...";

        // ---------------- Project sidebar (always visible) ----------------
        dcad_gui_set_next_window_pos(0, 0, condAlways);
        dcad_gui_set_next_window_size(sidebarWidth, vh, condAlways);
        if (dcad_gui_begin("Project", viewportPaneFlags))
        {
            float sx, sy, sw, sh;
            dcad_gui_get_window_pos(&sx, &sy);
            dcad_gui_get_window_size(&sw, &sh);
            float cx, cy;
            dcad_gui_get_cursor_screen_pos(&cx, &cy);
            immutable treeH = (sy + sh - 8f) - cy;
            if (dcad_gui_begin_child("##tree", 0,
                                     treeH > 40 ? treeH : 40,
                                     childFlagsNone))
                drawFileTree(root, "");
            dcad_gui_end_child();
        }
        dcad_gui_end();

        // ---------------- Editor pane ----------------
        dcad_gui_set_next_window_pos(sidebarWidth, 0, condAlways);
        dcad_gui_set_next_window_size(editorW, vh, condAlways);
        if (dcad_gui_begin("Script", fixedPaneFlags))
        {
            // Action row at the top of this pane; no menu-bar header.
            if (iconButton(iconPlay, "Run script (Cmd/Ctrl+Enter)") || doRun)
                doRun = true;
            dcad_gui_same_line();
            if (iconButton(iconSave, "Save script"))
            {
                import std.string : fromStringz;
                immutable target = currentFile.length
                    ? buildPath(root, currentFile) : stateFile;
                write(target, fromStringz(dcad_textedit_get_text(editor)).idup);
                status = "Saved " ~ target;
            }
            dcad_gui_same_line();
            dcad_gui_text_colored(displayName.toStringz,
                                  0.35f, 0.35f, 0.35f, 1);
            dcad_gui_separator();

            // Editor takes whatever is left after the status / error strip, so
            // the pane fits vertically. Scrolling stays enabled for long files.
            float wx, wy, ww, wh;
            dcad_gui_get_window_pos(&wx, &wy);
            dcad_gui_get_window_size(&ww, &wh);
            float cursorX, cursorY;
            dcad_gui_get_cursor_screen_pos(&cursorX, &cursorY);
            immutable bottomReserve = showError ? 168f : 64f;
            immutable available = (wy + wh - 8f) - cursorY - bottomReserve;
            immutable editorH = available > 80 ? available : 80;
            dcad_textedit_render(editor, "##script", ww - 24, editorH);

            dcad_gui_text_colored(status.toStringz, 0.63f, 0.71f, 0.42f, 1);

            if (showError && lastError.length)
            {
                dcad_gui_text_colored("ERROR:".toStringz, 0.67f, 0.27f, 0.26f, 1);
                float errX, errY;
                dcad_gui_get_cursor_screen_pos(&errX, &errY);
                immutable errRoom = (wy + wh - 8f) - errY;
                if (dcad_gui_begin_child("##error", 0,
                                         errRoom > 60 ? errRoom : 60,
                                         childFlagsBorders))
                    dcad_gui_text_wrapped(lastError.toStringz);
                dcad_gui_end_child();
            }
        }
        dcad_gui_end();

        // Run after the editor frame so text is up to date.
        if (doRun)
            doRunScript();

        // ---------------- Viewport pane ----------------
        dcad_gui_set_next_window_pos(sidebarWidth + editorW, 0, condAlways);
        dcad_gui_set_next_window_size(viewportW, vh, condAlways);
        if (dcad_gui_begin("3D Viewport", viewportPaneFlags))
        {
            float x, y, w, h;
            dcad_gui_get_window_pos(&x, &y);
            dcad_gui_get_window_size(&w, &h);

            // Row 1: standard views, with Fit and a full camera reset.
            if (iconButton(iconFit, "Fit all")) viewport.fitAll();
            dcad_gui_same_line();
            if (iconButton(iconCube, "Isometric view")) viewport.viewIso();
            dcad_gui_same_line();
            if (iconButton(iconUp, "Top view")) viewport.viewTop();
            dcad_gui_same_line();
            if (iconButton(iconDown, "Bottom view")) viewport.viewBottom();
            dcad_gui_same_line();
            if (iconButton(iconFront, "Front view")) viewport.viewFront();
            dcad_gui_same_line();
            if (iconButton(iconBack, "Back view")) viewport.viewBack();
            dcad_gui_same_line();
            if (iconButton(iconRight, "Right view")) viewport.viewRight();
            dcad_gui_same_line();
            if (iconButton(iconLeft, "Left view")) viewport.viewLeft();
            dcad_gui_same_line();
            if (iconButton(iconRefresh, "Reset camera")) viewport.resetCamera();

            // Row 2: display toggles and OCCT mesh density.
            if (toggleIconButton(iconCrosshair, "Axes", viewport.axesEnabled()))
                viewport.setAxes(!viewport.axesEnabled());
            dcad_gui_same_line();
            if (toggleIconButton(iconGrid, "Grid", viewport.gridEnabled()))
                viewport.setGrid(!viewport.gridEnabled());
            dcad_gui_same_line();
            if (toggleIconButton(iconWire, "Wireframe",
                                 viewport.wireframeEnabled()))
                viewport.setWireframe(!viewport.wireframeEnabled());
            dcad_gui_same_line();
            if (toggleIconButton(iconSquare, "Orthographic projection",
                                 viewport.orthographicEnabled()))
                viewport.setOrthographic(!viewport.orthographicEnabled());
            dcad_gui_same_line();
            dcad_gui_set_next_item_width(110);
            if (dcad_gui_slider_float("Deflection", &deflection, 0.05f, 5.0f) != 0 &&
                currentShape !is null)
            {
                int tris;
                if (hasAnimation)
                {
                    const(void)*[] ptrs;
                    foreach (i; 0 .. host.animPartCount())
                    {
                        auto p = host.animPartShape(i);
                        if (p !is null) ptrs ~= p;
                    }
                    tris = viewport.setParts(ptrs, deflection);
                }
                else
                    tris = viewport.setShape(
                        cast(const(void)*)&currentShape.native(), deflection);
                status = "Remeshed - " ~ tris.to!string ~ " triangles";
            }

            // Row 3: OpenSCAD-style animation panel for opt-in scripts.
            if (hasAnimation)
            {
                if (toggleIconButton(animPlaying ? iconPause : iconPlay,
                                     "Play/Pause animation", animPlaying))
                    animPlaying = !animPlaying;
                dcad_gui_same_line();
                if (iconButton(iconRestart, "Restart animation"))
                {
                    animTime = 0;
                    animPlaying = true;
                }
                dcad_gui_same_line();
                dcad_gui_text(("  $t = " ~ format("%.2f",
                    animTime / cycleSeconds())).toStringz);
                dcad_gui_same_line();
                dcad_gui_set_next_item_width(100);
                float timeF = cast(float) animTime;
                if (dcad_gui_slider_float("Time", &timeF, 0,
                                          cast(float) cycleSeconds()) != 0)
                    animTime = timeF;
                dcad_gui_same_line();
                dcad_gui_set_next_item_width(50);
                if (dcad_gui_input_float("FPS", &animFps, 1) != 0 && animFps < 1)
                    animFps = 1;
                dcad_gui_same_line();
                dcad_gui_set_next_item_width(55);
                if (dcad_gui_input_int("Steps", &animSteps, 1) != 0 &&
                    animSteps < 1)
                    animSteps = 1;
            }
            dcad_gui_separator();

            // The canvas takes exactly the space left in the pane.
            float cursorX, cursorY;
            dcad_gui_get_cursor_screen_pos(&cursorX, &cursorY);
            immutable imgW = w - 16 > 16 ? w - 16 : 16;
            immutable remaining = (y + h - 8f) - cursorY;
            immutable imgH = remaining > 80 ? remaining : 80;

            // Camera interaction: left drag orbit, right/middle drag pan, wheel zoom.
            if (dcad_gui_is_window_hovered())
            {
                float dx, dy;
                dcad_gui_get_io_mouse_delta(&dx, &dy);
                if (dcad_gui_mouse_down(mouseLeft))
                    viewport.orbit(dx, dy);
                else if (dcad_gui_mouse_down(mouseMiddle) ||
                         dcad_gui_mouse_down(mouseRight))
                    viewport.pan(dx, dy);

                const wheel = dcad_gui_get_mouse_wheel_y();
                if (wheel != 0)
                    viewport.zoom(wheel);
            }

            // Advance the animation. Only a translation uniform is uploaded;
            // the OCCT meshes stay static for the whole playback.
            immutable now = glfwGetTime();
            if (hasAnimation)
            {
                immutable cycle = cycleSeconds();
                if (animPlaying)
                    animTime += now - lastFrameTime;
                while (animTime >= cycle)
                    animTime -= cycle;
                viewport.setOffsets(host.animPose(animTime / cycle,
                                                  host.animPartCount()));
            }
            lastFrameTime = now;

            // Render the FBO at the panel's pixel size, then display it.
            immutable pw = cast(int)(imgW * 2);
            immutable ph = cast(int)(imgH * 2);
            viewport.render(pw, ph);
            dcad_gui_image(viewport.textureID(), imgW, imgH);

            // Parts list: a transparent overlay on the render, with no pane,
            // border or background. Hovering a row highlights that part.
            if (hasAnimation)
            {
                immutable rowH = 19f;
                immutable startX = cursorX + imgW - partsOverlayWidth - 6f;
                immutable startY = cursorY + 6f;
                foreach (i; 0 .. host.animPartCount())
                {
                    auto name = host.animPartName(cast(int) i);
                    if (name is null || !name.length)
                        name = "Part " ~ (i + 1).to!string;
                    immutable rowY = startY + cast(float) i * rowH;

                    dcad_gui_set_cursor_screen_pos(startX, rowY);
                    dcad_gui_icon_image(iconTexture(iconCube), 14, 14);
                    dcad_gui_set_cursor_screen_pos(startX + 18f, rowY);
                    dcad_gui_text(name.toStringz);

                    dcad_gui_set_cursor_screen_pos(startX - 3f, rowY - 2f);
                    dcad_gui_invisible_button(("##part" ~ i.to!string).toStringz,
                                              partsOverlayWidth, rowH);
                    if (dcad_gui_is_item_hovered())
                    {
                        hoveredPart = cast(int) i;
                        dcad_gui_set_item_tooltip(
                            ("Highlight " ~ name).toStringz);
                    }
                }
            }
            viewport.setHighlightPart(hoveredPart);
        }
        dcad_gui_end();

        dcad_gui_render();
        glfwSwapBuffers(window);
    }
}

private string repoRoot()
{
    // The GUI runs from the repository root via `dub run :gui`.
    import std.file : getcwd;
    return getcwd();
}
