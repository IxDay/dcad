/**
 * dcad-gui -- project tree, Code/Agent editor + live 3D preview.
 *
 * Left pane: project tree.
 * Middle pane: fixed Code (ImGuiColorTextEdit) / Agent (OpenCode) tabs.
 * Right pane: OpenGL framebuffer texture showing the resulting OCCT shape.
 * Run with Ctrl+Enter (Cmd+Enter on macOS) or the Run button.
 */
module gui.app;

import std.stdio : stderr, writeln;
import std.file : mkdirRecurse, exists, readText, write, dirEntries, SpanMode, isDir, tempDir;
import std.path : buildPath, baseName, dirName, extension;
import std.string : toStringz, format, startsWith, endsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.process : environment;

import gui.agent : AgentBridge, AgentRole;
import gui.platform : processId, nativeHandles, resourceRoot;
import gui.project : Project, chooseProjectParent, fallbackProjectParent,
                     uniqueProjectPath;

import bindbc.glfw;
import bindbc.opengl;

import gui.imgui;
import gui.viewport : Viewport, ShaderMode;
import gui.script_host : ScriptHost, RunResult;

import dcad.shape : Shape;

// Native menus call back into D with plain C function pointers. The shader
// callback is static state; New Project needs the editor's local variables, so
// it dispatches through a short-lived delegate installed for the session.
private Viewport g_menuViewport;
private void delegate() g_newProjectAction;

extern(C) void dcad_shader_menu_callback(int mode)
{
    if (g_menuViewport is null) return;
    g_menuViewport.setShaderMode(mode == 1 ? ShaderMode.wood
                                           : ShaderMode.vscodeYellow);
}

extern(C) void dcad_new_project_callback()
{
    if (g_newProjectAction !is null)
        g_newProjectAction();
}

// Startup opens a real, tracked script file. There is no hidden session file.
private enum string defaultProjectDir = "samples/coffee-table";
// Layout values are authored at 100% and multiplied by the display scale.
private enum float sidebarWidthBase = 220f;
private enum float partsOverlayWidthBase = 170f;
private enum float iconSizeBase = 18f;
private float uiScale = 1f;
private float sidebarWidth = sidebarWidthBase;
private float partsOverlayWidth = partsOverlayWidthBase;
private float iconSize = iconSizeBase;

private float px(float value)
{
    return value * uiScale;
}

// Split the space left after the sidebar: 3/5 code editor, 2/5 preview.
private enum float editorShare = 3.0f / 5.0f;

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

/// Source module of an animation part, from its stable id. The part ids are
/// shared with the motion keyframes, so this stays a pure naming convention:
/// clicking a row in the parts list opens the file that builds that geometry.
private string partSourceFile(string id, string projectRoot)
{
    if (id.length == 0) return null;
    // A project's part ids are its source file names (part-a.d, key.d, ...).
    // That keeps new projects free of GUI-side naming conventions.
    auto local = buildPath(projectRoot, id ~ ".d");
    if (exists(local)) return id ~ ".d";

    string moduleName;
    if (id.startsWith("leg-"))                   moduleName = "leg";
    else if (id.startsWith("apron-side-"))       moduleName = "side_apron";
    else if (id.startsWith("apron-end-"))        moduleName = "end_apron";
    else if (id.startsWith("rail-cross-"))       moduleName = "cross_rail";
    else if (id.startsWith("top-") && id.endsWith("-outer"))
                                                  moduleName = "top_outer";
    else if (id.startsWith("top-") && id.endsWith("-inner"))
                                                  moduleName = "top_inner";
    else if (id.startsWith("wedge-"))            moduleName = "wedge";
    else return null;

    // New projects opened from the sample directory use flat module names;
    // older launches used the cache root with samples/coffee-table nested.
    auto relative = moduleName ~ ".d";
    if (exists(buildPath(projectRoot, relative))) return relative;
    relative = buildPath(defaultProjectDir, moduleName ~ ".d");
    if (exists(buildPath(projectRoot, relative))) return relative;
    return null;
}

/// Name of a release plugin that can replace the first startup compile. The
/// key beside the plugin is checked before it is used, so a user-edited source
/// still falls back to the normal compiler.
private string precompiledBase(string root, string projectRoot,
                               string currentFile)
{
    if (projectRoot == buildPath(root, "samples", "coffee-table") &&
        currentFile == "table.d")
        return "dcad-coffee-table";
    if (currentFile == "main.d" &&
        exists(buildPath(projectRoot, ".dcad.toml")))
        return "dcad-daimochi";
    return null;
}

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
    // All runtime files live beside the released binary. In a source checkout
    // the repository root is found instead, so `dub run :gui` keeps working.
    immutable root = resourceRoot();
    dcad_gui_set_resource_root(root.toStringz);

    // Headless acceptance hook: proves the packaged launcher actually started
    // the embedded GUI before any GLFW/window work is attempted.
    immutable smokeFile = environment.get("DCAD_SMOKE_FILE", "");
    if (smokeFile.length)
    {
        write(smokeFile, root);
        return;
    }

    // Project handler: `dcad-gui <project-dir|.dcad.toml|source.d>` opens a
    // project, while `--new-project <target-dir>` scaffolds the daimochi
    // sample and opens it. With no argument the bundled coffee table is used.
    Project project;
    if (args.length > 1 && args[1] == "--new-project")
    {
        immutable target = args.length > 2
            ? args[2] : uniqueProjectPath(fallbackProjectParent(),
                                          "daimochi-tsugi");
        try
            project = Project.create(target, root);
        catch (Exception e)
            stderr.writeln("new project failed: ", e.msg);
    }
    else if (args.length > 1)
    {
        try
            project = Project.open(args[1]);
        catch (Exception e)
            stderr.writeln("cannot open project ", args[1], ": ", e.msg);
    }
    if (project.root.length == 0)
        project = Project.bundled(root);
    string projectRoot = project.root;
    string currentFile = project.entry;

    // Agent sessions live in the app cache, one per project root. The CLI runs
    // with projectRoot as its cwd, so tools and credentials are the user's own.
    auto agent = new AgentBridge();
    agent.open(projectRoot, project.name);
    scope(exit)
    {
        agent.close();
        agent.persist();
    }

    // --- GLFW / OpenGL ----------------------------------------------------
    // On Windows a DPI-unaware process reports virtualised window sizes, so
    // the framebuffer/window ratio below would always be 1 and the UI would
    // stay tiny on high-DPI displays. Do this before GLFW creates any window.
    dcad_gui_enable_dpi_awareness();
    if (glfwInit() != GLFW_TRUE)
    {
        stderr.writeln("failed to initialise GLFW");
        return;
    }
    scope(exit) glfwTerminate();

    // Size to the monitor so a 120-character editor still leaves a useful
    // preview pane. The window stays smaller than the screen on small displays.
    auto mode = glfwGetVideoMode(glfwGetPrimaryMonitor());
    int windowW = 1440;
    int windowH = 900;
    if (mode !is null)
    {
        windowW = mode.width;
        windowH = mode.height - 60;
    }

    // macOS needs a compatibility profile for GL 2.1 shaders (GLSL 120).
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 2);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
    auto window = glfwCreateWindow(windowW, windowH, "dcad - editor + preview",
                                   null, null);
    if (window is null)
    {
        stderr.writeln("failed to create GLFW window");
        return;
    }
    scope(exit) glfwDestroyWindow(window);
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    // ImGui coordinates are framebuffer pixels; GLFW window sizes are screen
    // points. Content scale and framebuffer/window ratio are both checked:
    // GLFW reports one or the other depending on platform and GL version.
    // DCAD_UI_SCALE remains an explicit override for mixed-DPI setups.
    float forcedScale = 0f;
    immutable scaleOverride = environment.get("DCAD_UI_SCALE", "");
    if (scaleOverride.length)
    {
        try
            forcedScale = scaleOverride.to!float;
        catch (Exception)
            forcedScale = 0f;
    }
    bool imguiReady;

    float detectedScale(GLFWwindow* w)
    {
        float sx = 0f, sy = 0f;
        glfwGetWindowContentScale(w, &sx, &sy);
        float scale = sx > sy ? sx : sy;
        int framebufferW, framebufferH, windowWPoints, windowHPoints;
        glfwGetFramebufferSize(w, &framebufferW, &framebufferH);
        glfwGetWindowSize(w, &windowWPoints, &windowHPoints);
        if (windowWPoints > 0 && framebufferW > 0)
        {
            immutable ratio = cast(float) framebufferW / windowWPoints;
            if (ratio > scale) scale = ratio;
        }
        return scale > 0f ? scale : 1f;
    }

    void refreshUiScale(GLFWwindow* w)
    {
        immutable requested = forcedScale > 0f ? forcedScale : detectedScale(w);
        immutable clamped = requested < 0.5f ? 0.5f
                          : requested > 4f ? 4f : requested;
        if (clamped > uiScale + 0.01f || clamped < uiScale - 0.01f)
        {
            uiScale = clamped;
            sidebarWidth = px(sidebarWidthBase);
            partsOverlayWidth = px(partsOverlayWidthBase);
            iconSize = px(iconSizeBase);
            dcad_gui_set_scale(uiScale);
            if (imguiReady) dcad_gui_apply_light_theme();
        }
    }

    refreshUiScale(window);

    void updateTitle()
    {
        auto label = "dcad - " ~ project.name ~ " - " ~ baseName(currentFile);
        glfwSetWindowTitle(window, label.toStringz);
    }
    updateTitle();

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
    imguiReady = true;

    // --- Application state ------------------------------------------------
    auto editor = dcad_textedit_new();
    scope(exit) dcad_textedit_free(editor);
    dcad_textedit_set_light_palette(editor);

    // Hot-load artefacts live in the system temp dir, never in the repo.
    immutable workDir = buildPath(tempDir(), "dcad-gui-" ~ processId.to!string);
    mkdirRecurse(workDir);

    auto host = new ScriptHost(workDir, root, project.root);
    auto viewport = new Viewport();
    scope(exit) viewport.dispose(); // context is still current at scope exit

    g_menuViewport = viewport;
    scope(exit) g_menuViewport = null;
    auto native = nativeHandles(cast(void*) window);
    dcad_install_native_menu(native.window, native.display,
                             &dcad_shader_menu_callback,
                             &dcad_new_project_callback);

    // Open a real project file, so the tab name is always truthful and Save
    // never needs a hidden scratch destination.
    dcad_textedit_set_text(editor,
                           readText(buildPath(projectRoot, currentFile)).toStringz);

    string status = "Ready - press Ctrl+Enter (Cmd+Enter) or Run";
    string lastError;
    bool showError;
    float deflection = 1.0f;
    Shape currentShape;

    // Editor pane tabs. The prompt buffer is fixed so ImGui never reallocates
    // it while the UI owns the text; it is cleared after a successful send.
    enum size_t agentPromptCapacity = 8192;
    char[agentPromptCapacity] agentPrompt;
    agentPrompt[] = '\0';
    int currentTab;
    ulong agentRevision = agent.revision;
    bool suppressRun;

    // Project tree state.
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
                    iconTexture(open != 0 ? iconFolderOpen : iconFolder), px(16), px(16));
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
                dcad_gui_icon_image(iconTexture(fi.texture), px(16), px(16));
                dcad_gui_same_line();
                if (dcad_gui_selectable(e.name.toStringz, selected) != 0)
                {
                    try
                    {
                        dcad_textedit_set_text(editor, readText(e.path).toStringz);
                        currentFile = key;
                        status = "Opened " ~ key;
                        updateTitle();
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
        RunResult result;
        try
            result = host.runPrecompiled(
                src, precompiledBase(root, projectRoot, currentFile));
        catch (Exception e)
            result = RunResult(null, "script host failed: " ~ e.msg);
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
        }
    }

    // Initial run so the viewport is not empty on startup.
    doRunScript();

    /// File > New Project: choose a parent directory, scaffold the daimochi
    /// sample from the embedded template, switch the host to it and rebuild.
    void createNewProject()
    {
        bool usedFallback = false;
        auto parent = chooseProjectParent();
        if (parent is null)
        {
            parent = fallbackProjectParent();
            usedFallback = true;
            mkdirRecurse(parent);
        }

        try
        {
            auto created = Project.create(
                uniqueProjectPath(parent, "daimochi-tsugi"), root);
            destroy(host);
            host = new ScriptHost(workDir, root, created.root);
            project = created;
            projectRoot = created.root;
            currentFile = created.entry;
            agent.open(created.root, created.name);
            agentPrompt[] = '\0';
            agentRevision = agent.revision;
            dcad_textedit_set_text(editor,
                                   readText(created.entryPath()).toStringz);
            updateTitle();
            doRunScript();
            status = "Created " ~ created.root
                   ~ (usedFallback ? " (folder picker unavailable)" : "");
        }
        catch (Exception e)
            status = "New project failed: " ~ e.msg;
    }

    g_newProjectAction = &createNewProject;
    scope(exit) g_newProjectAction = null;

    // --- Main loop --------------------------------------------------------
    while (glfwWindowShouldClose(window) == 0)
    {
        // X11 needs to drain events for the menu bar's own windows before
        // GLFW polls; other platforms make this a no-op.
        dcad_native_menu_poll();
        glfwPollEvents();
        // Moving the window to a monitor with a different DPI changes the
        // framebuffer ratio; rebuild fonts and layout when that happens.
        refreshUiScale(window);
        // CLI output is collected on a reader thread; move it to GUI-owned
        // state before any widget reads the transcript.
        agent.drain();
        dcad_gui_new_frame();

        // Fixed layout rebuilt every frame: project tree / editor / preview.
        // Nothing can be dragged, resized or re-docked. The parts list is an
        // overlay inside the preview, not a fourth pane.
        float vw, vh;
        dcad_gui_get_viewport_size(&vw, &vh);
        // Fixed 3/5 - 2/5 split of the space left after the sidebar: nothing
        // can be dragged or resized, and the preview never gets squeezed out.
        immutable availableW = vw - sidebarWidth;
        immutable editorW = availableW * editorShare;
        immutable viewportW = availableW - editorW;
        int hoveredPart = -1;
        bool uiCaptured;

        // Run trigger: global key chord, or the editor's Run button. This is
        // recomputed per frame; the Agent tab clears it before it can reach
        // the script host.
        bool doRun = dcad_gui_key_chord_pressed(modCtrl | keyEnter) != 0;
        suppressRun = false;

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
            immutable treeH = (sy + sh - px(8)) - cy;
            if (dcad_gui_begin_child("##tree", 0,
                                     treeH > px(40) ? treeH : px(40),
                                     childFlagsNone))
                drawFileTree(projectRoot, "");
            dcad_gui_end_child();
        }
        dcad_gui_end();

        // ---------------- Editor pane ----------------
        // Computed here so a click in the file tree updates the label on the
        // same frame. The built-in script gets a real name, never "untitled".
        auto displayName = currentFile.length
            ? baseName(currentFile) : "default.d";
        if (displayName.length > 20)
            displayName = displayName[0 .. 17] ~ "...";

        dcad_gui_set_next_window_pos(sidebarWidth, 0, condAlways);
        dcad_gui_set_next_window_size(editorW, vh, condAlways);
        if (dcad_gui_begin("Script", fixedPaneFlags))
        {
            // Two fixed views share this pane. Neither tab can be dragged,
            // reordered or closed, so the pane split itself stays fixed.
            int activeTab = currentTab;
            if (dcad_gui_begin_tab_bar("##code-tabs", tabBarFlagsNone))
            {
                if (dcad_gui_begin_tab_item("Code", tabItemFlagsNoReorder))
                {
                    activeTab = 0;
                    dcad_gui_end_tab_item();
                }
                if (dcad_gui_begin_tab_item("Agent", tabItemFlagsNoReorder))
                {
                    activeTab = 1;
                    dcad_gui_end_tab_item();
                }
                dcad_gui_end_tab_bar();
            }
            currentTab = activeTab;
            dcad_gui_separator();

            float wx, wy, ww, wh;
            dcad_gui_get_window_pos(&wx, &wy);
            dcad_gui_get_window_size(&ww, &wh);

            if (activeTab == 0)
            {
                // Action row at the top of this pane; no menu-bar header.
                if (iconButton(iconPlay, "Run script (Cmd/Ctrl+Enter)") || doRun)
                    doRun = true;
                dcad_gui_same_line();
                if (iconButton(iconSave, "Save script"))
                {
                    import std.string : fromStringz;
                    if (!currentFile.length)
                        currentFile = project.entry;
                    immutable target = buildPath(projectRoot, currentFile);
                    write(target, fromStringz(dcad_textedit_get_text(editor)).idup);
                    status = "Saved " ~ target;
                    updateTitle();
                }
                dcad_gui_same_line();
                dcad_gui_align_text_to_frame_padding();
                dcad_gui_text_colored(displayName.toStringz,
                                      0.35f, 0.35f, 0.35f, 1);
                dcad_gui_separator();

                // Editor takes whatever is left after the status / error strip,
                // so the pane fits vertically. Scrolling stays enabled for
                // long files.
                float cursorX, cursorY;
                dcad_gui_get_cursor_screen_pos(&cursorX, &cursorY);
                immutable bottomReserve = showError ? px(168) : px(64);
                immutable available = (wy + wh - px(8)) - cursorY - bottomReserve;
                immutable editorH = available > px(80) ? available : px(80);
                dcad_textedit_render(editor, "##script", ww - px(24), editorH);

                dcad_gui_text_colored(status.toStringz, 0.63f, 0.71f, 0.42f, 1);

                if (showError && lastError.length)
                {
                    dcad_gui_text_colored("ERROR:".toStringz,
                                          0.67f, 0.27f, 0.26f, 1);
                    float errX, errY;
                    dcad_gui_get_cursor_screen_pos(&errX, &errY);
                    immutable errRoom = (wy + wh - px(8)) - errY;
                    if (dcad_gui_begin_child("##error", 0,
                                             errRoom > px(60) ? errRoom : px(60),
                                             childFlagsBorders))
                        dcad_gui_text_wrapped(lastError.toStringz);
                    dcad_gui_end_child();
                }
            }
            else
            {
                // Cmd/Ctrl+Enter belongs to the chat input here; script Run
                // stays on the Code tab.
                suppressRun = true;
                auto sessionLabel = agent.sessionId.length
                    ? "opencode session " ~ agent.sessionId
                    : "opencode session (new)";
                dcad_gui_text_colored(sessionLabel.toStringz,
                                      0.35f, 0.35f, 0.35f, 1);
                dcad_gui_separator();

                float cursorX, cursorY;
                dcad_gui_get_cursor_screen_pos(&cursorX, &cursorY);
                immutable logReserve = px(140);
                immutable logRoom = (wy + wh - px(8)) - cursorY - logReserve;
                if (dcad_gui_begin_child("##agent-log", 0,
                                         logRoom > px(80) ? logRoom : px(80),
                                         childFlagsBorders))
                {
                    foreach (msg; agent.messages)
                    {
                        string prefix;
                        float r, g, b;
                        final switch (msg.role)
                        {
                            case AgentRole.user:
                                prefix = "You: ";
                                r = 0.49f; g = 0.69f; b = 0.76f;
                                break;
                            case AgentRole.assistant:
                                prefix = "Agent: ";
                                r = 0.22f; g = 0.22f; b = 0.22f;
                                break;
                            case AgentRole.tool:
                                prefix = "Tool: ";
                                r = 0.40f; g = 0.40f; b = 0.40f;
                                break;
                            case AgentRole.error:
                                prefix = "Error: ";
                                r = 0.67f; g = 0.27f; b = 0.26f;
                                break;
                            case AgentRole.status:
                                prefix = "";
                                r = 0.56f; g = 0.56f; b = 0.56f;
                                break;
                        }
                        dcad_gui_text_colored(
                            (prefix ~ msg.text ~ "\n\n").toStringz, r, g, b, 1);
                    }
                    if (agent.revision != agentRevision)
                    {
                        dcad_gui_set_scroll_here_y(1.0f);
                        agentRevision = agent.revision;
                    }
                }
                dcad_gui_end_child();

                dcad_gui_spacing();
                dcad_gui_input_text_multiline("##agent-prompt", agentPrompt.ptr,
                    cast(int) agentPrompt.length, ww - px(24), px(64),
                    inputTextFlagsCtrlEnterForNewLine |
                    inputTextFlagsNoHorizontalScroll |
                    inputTextFlagsWordWrap);
                bool sendPressed = false;
                if (dcad_gui_is_item_active() != 0)
                {
                    // Enter sends; Cmd/Ctrl+Enter inserts a newline. The global
                    // Cmd/Ctrl+Enter script shortcut is suppressed below.
                    if (dcad_gui_key_chord_pressed(keyEnter) != 0)
                        sendPressed = true;
                }
                if (dcad_gui_button(agent.busy ? "Running..." : "Send") != 0)
                    sendPressed = true;
                if (sendPressed && !agent.busy)
                {
                    import std.string : fromStringz;
                    auto text = fromStringz(agentPrompt.ptr).idup;
                    if (agent.send(text, currentFile))
                    {
                        agentPrompt[] = '\0';
                        status = "Agent prompt sent";
                    }
                }
                dcad_gui_same_line();
                dcad_gui_align_text_to_frame_padding();
                dcad_gui_text_colored(agent.status.toStringz,
                                      0.63f, 0.71f, 0.42f, 1);
            }
        }
        dcad_gui_end();

        // Run after the editor frame so text is up to date.
        if (doRun && !suppressRun)
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
            dcad_gui_set_next_item_width(px(110));
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
                dcad_gui_set_next_item_width(px(50));
                if (dcad_gui_input_float("FPS", &animFps, 1) != 0 && animFps < 1)
                    animFps = 1;
                dcad_gui_same_line();
                dcad_gui_set_next_item_width(px(55));
                if (dcad_gui_input_int("Steps", &animSteps, 1) != 0 &&
                    animSteps < 1)
                    animSteps = 1;

                // Timeline: a bar that fills the full pane width. Its fill
                // grows with time (no moving cursor); click/drag to scrub.
                immutable cycle = cycleSeconds();
                dcad_gui_progress_bar(cast(float)(animTime / cycle),
                    dcad_gui_content_region_avail_x(), px(20),
                    format("  %.2f / %.2f s  ", animTime, cycle).toStringz);
                float barX0, barY0, barX1, barY1;
                dcad_gui_get_item_rect(&barX0, &barY0, &barX1, &barY1);
                float mx, my;
                dcad_gui_get_mouse_pos(&mx, &my);
                if (mx >= barX0 && mx <= barX1 && my >= barY0 && my <= barY1)
                {
                    uiCaptured = true;
                    if (dcad_gui_mouse_down(mouseLeft) && barX1 > barX0)
                        animTime = (mx - barX0) / (barX1 - barX0) * cycle;
                }
            }
            dcad_gui_separator();

            // The canvas takes exactly the space left in the pane.
            float cursorX, cursorY;
            dcad_gui_get_cursor_screen_pos(&cursorX, &cursorY);
            immutable imgW = w - px(16) > px(16) ? w - px(16) : px(16);
            immutable remaining = (y + h - px(8)) - cursorY;
            immutable imgH = remaining > px(80) ? remaining : px(80);

            // The parts overlay and the timeline own their mouse area; don't
            // let a click there also orbit the camera.
            if (hasAnimation)
            {
                immutable rowH = px(19);
                immutable startX = cursorX + imgW - partsOverlayWidth
                                   - px(6) - px(3);
                immutable startY = cursorY + px(6) - px(2);
                float mx, my;
                dcad_gui_get_mouse_pos(&mx, &my);
                if (mx >= startX && mx <= startX + partsOverlayWidth &&
                    my >= startY &&
                    my < startY + cast(float) host.animPartCount() * rowH)
                    uiCaptured = true;
            }

            // Camera interaction: left drag orbit, right/middle drag pan, wheel zoom.
            if (dcad_gui_is_window_hovered() && !uiCaptured)
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
                immutable rowH = px(19);
                immutable startX = cursorX + imgW - partsOverlayWidth - px(6);
                immutable startY = cursorY + px(6);
                foreach (i; 0 .. host.animPartCount())
                {
                    auto name = host.animPartName(cast(int) i);
                    if (name is null || !name.length)
                        name = "Part " ~ (i + 1).to!string;
                    immutable rowY = startY + cast(float) i * rowH;

                    dcad_gui_set_cursor_screen_pos(startX, rowY);
                    dcad_gui_icon_image(iconTexture(iconCube), px(14), px(14));
                    dcad_gui_set_cursor_screen_pos(startX + px(18), rowY);
                    dcad_gui_text(name.toStringz);

                    dcad_gui_set_cursor_screen_pos(startX - px(3),
                                                   rowY - px(2));
                    auto ident = host.animPartId(cast(int) i);
                    auto rel = partSourceFile(ident, projectRoot);
                    if (rel is null) rel = partSourceFile(name, projectRoot);
                    if (dcad_gui_invisible_button(
                            ("##part" ~ i.to!string).toStringz,
                            partsOverlayWidth, rowH) != 0 && rel !is null)
                    {
                        try
                        {
                            dcad_textedit_set_text(
                                editor,
                                readText(buildPath(projectRoot, rel)).toStringz);
                            currentFile = rel;
                            status = "Opened " ~ rel;
                            updateTitle();
                        }
                        catch (Exception)
                        {
                            status = "Cannot open " ~ rel;
                        }
                    }
                    if (dcad_gui_is_item_hovered())
                    {
                        hoveredPart = cast(int) i;
                        dcad_gui_set_item_tooltip(rel is null
                            ? ("Highlight " ~ name).toStringz
                            : ("Open " ~ rel).toStringz);
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
