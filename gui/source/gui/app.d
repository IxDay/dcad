/**
 * dcad-gui -- two-pane editor + live 3D preview.
 *
 * Left pane: ImGuiColorTextEdit holding a D script.
 * Right pane: OpenGL framebuffer texture showing the resulting OCCT shape.
 * Run with Ctrl+Enter (Cmd+Enter on macOS) or the Run button.
 */
module gui.app;

import std.stdio : stderr, writeln;
import std.file : mkdirRecurse, exists, readText, write;
import std.path : buildPath;
import std.string : toStringz, format;
import std.conv : to;

import bindbc.glfw;
import bindbc.opengl;

import gui.imgui;
import gui.viewport : Viewport;
import gui.script_host : ScriptHost, RunResult;

import dcad.shape : Shape;

extern(C) nothrow @nogc int dcad_guarded_step_write(const(void)* shape, const(char)* path);

private enum string defaultScript = q{// dcad script -- must end with `result` (a Shape or Workplane).
auto model = Workplane.create()
    .box(60, 40, 20)
    .faces(FaceSelector.top)
    .circle(8)
    .cutThruAll();

Shape result = model.shape;
};

private enum string stateFile = ".dcad-gui-state";

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
    dcad_gui_apply_light_theme(); // brocanth-ui "original", light variant

    // --- Application state ------------------------------------------------
    auto editor = dcad_textedit_new();
    scope(exit) dcad_textedit_free(editor);
    dcad_textedit_set_light_palette(editor);

    immutable workDir = buildPath(".dcad-gui-scripts");
    mkdirRecurse(workDir);
    scope(exit) { /* keep generated scripts out of the repo via gitignore */ }

    auto host = new ScriptHost(workDir, repoRoot());
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

        // Fixed two-pane split: 44% editor / 56% viewport, rebuilt every
        // frame so neither pane can be dragged, resized or re-docked.
        float vw, vh;
        dcad_gui_get_viewport_size(&vw, &vh);
        immutable editorW = vw * 0.44f;

        // Run trigger: key chord checked globally, button in editor window.
        bool doRun = dcad_gui_key_chord_pressed(modCtrl | keyEnter) != 0;

        // ---------------- Editor pane ----------------
        dcad_gui_set_next_window_pos(0, 0, condAlways);
        dcad_gui_set_next_window_size(editorW, vh, condAlways);
        if (dcad_gui_begin("Script", fixedPaneFlags | windowFlagsMenuBar))
        {
            if (dcad_gui_begin_menu_bar())
            {
                if (dcad_gui_begin_menu("File"))
                {
                    if (dcad_gui_menu_item("Reset to example", null, 0, 1))
                        dcad_textedit_set_text(editor, defaultScript.toStringz);
                    dcad_gui_end_menu();
                }
                dcad_gui_end_menu_bar();
            }

            if (dcad_gui_button("Run (Ctrl/Cmd+Enter)") || doRun)
                doRun = true;

            dcad_gui_same_line();
            if (dcad_gui_button("Reset camera"))
                viewport.resetCamera();
            dcad_gui_same_line();
            if (dcad_gui_button("Export STEP") && currentShape !is null)
            {
                if (dcad_guarded_step_write(&currentShape.native(),
                                            "dcad-export.step".toStringz) == 0)
                    status = "Exported dcad-export.step";
                else
                    status = "STEP export failed";
            }

            dcad_gui_separator();

            // Editor fills the remaining space.
            float wx, wy, ww, wh;
            dcad_gui_get_window_pos(&wx, &wy);
            dcad_gui_get_window_size(&ww, &wh);
            immutable editorH = wh - 150 > 100 ? wh - 150 : 100;
            dcad_textedit_render(editor, "##script", ww - 24, editorH);

            if (dcad_gui_button("Save script"))
            {
                import std.string : fromStringz;
                write(stateFile, fromStringz(dcad_textedit_get_text(editor)).idup);
                status = "Saved " ~ stateFile;
            }

            dcad_gui_text_colored(status.toStringz, 0.05f, 0.45f, 0.20f, 1);

            if (showError && lastError.length)
            {
                dcad_gui_text_colored("ERROR:".toStringz, 0.75f, 0.15f, 0.15f, 1);
                if (dcad_gui_begin_child("##error", 0, 90, 1))
                    dcad_gui_text_wrapped(lastError.toStringz);
                dcad_gui_end_child();
            }
        }
        dcad_gui_end();

        // Run after the editor frame so text is up to date.
        if (doRun)
            doRunScript();

        // ---------------- Viewport pane ----------------
        dcad_gui_set_next_window_pos(editorW, 0, condAlways);
        dcad_gui_set_next_window_size(vw - editorW, vh, condAlways);
        if (dcad_gui_begin("3D Viewport", viewportPaneFlags))
        {
            float x, y, w, h;
            dcad_gui_get_window_pos(&x, &y);
            dcad_gui_get_window_size(&w, &h);

            // --- OpenSCAD-style view toolbar -------------------------------
            if (dcad_gui_button("Fit")) viewport.fitAll();
            dcad_gui_same_line();
            if (dcad_gui_button("Iso")) viewport.viewIso();
            dcad_gui_same_line();
            if (dcad_gui_button("Top")) viewport.viewTop();
            dcad_gui_same_line();
            if (dcad_gui_button("Bottom")) viewport.viewBottom();
            dcad_gui_same_line();
            if (dcad_gui_button("Front")) viewport.viewFront();
            dcad_gui_same_line();
            if (dcad_gui_button("Back")) viewport.viewBack();
            dcad_gui_same_line();
            if (dcad_gui_button("Right")) viewport.viewRight();
            dcad_gui_same_line();
            if (dcad_gui_button("Left")) viewport.viewLeft();

            int flag = viewport.axesEnabled() ? 1 : 0;
            if (dcad_gui_checkbox("Axes", &flag)) viewport.setAxes(flag != 0);
            dcad_gui_same_line();
            flag = viewport.gridEnabled() ? 1 : 0;
            if (dcad_gui_checkbox("Grid", &flag)) viewport.setGrid(flag != 0);
            dcad_gui_same_line();
            flag = viewport.wireframeEnabled() ? 1 : 0;
            if (dcad_gui_checkbox("Wireframe", &flag))
                viewport.setWireframe(flag != 0);
            dcad_gui_same_line();
            flag = viewport.orthographicEnabled() ? 1 : 0;
            if (dcad_gui_checkbox("Ortho", &flag))
                viewport.setOrthographic(flag != 0);

            dcad_gui_same_line();
            dcad_gui_set_next_item_width(150);
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
            dcad_gui_separator();

            // --- OpenSCAD-style animation panel -----------------------------
            // Placed above the canvas so the image can absorb all remaining
            // vertical space; no child window, so there is no scrollbar.
            if (hasAnimation)
            {
                int animate = animPlaying ? 1 : 0;
                if (dcad_gui_checkbox("Animate", &animate))
                    animPlaying = animate != 0;
                dcad_gui_same_line();
                if (dcad_gui_button("Restart"))
                {
                    animTime = 0;
                    animPlaying = true;
                }
                dcad_gui_same_line();
                immutable tNorm = animTime / cycleSeconds();
                dcad_gui_text(("  $t = " ~ format("%.2f", tNorm)).toStringz);

                float timeF = cast(float) animTime;
                dcad_gui_set_next_item_width(240);
                if (dcad_gui_slider_float("Time", &timeF, 0,
                                          cast(float) cycleSeconds()) != 0)
                    animTime = timeF;

                dcad_gui_set_next_item_width(90);
                if (dcad_gui_input_float("FPS", &animFps, 1) != 0 && animFps < 1)
                    animFps = 1;
                dcad_gui_same_line();
                dcad_gui_set_next_item_width(90);
                if (dcad_gui_input_int("Steps", &animSteps, 1) != 0 &&
                    animSteps < 1)
                    animSteps = 1;
                dcad_gui_separator();
            }

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
