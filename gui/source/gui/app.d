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
import std.string : toStringz;
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
    double animTime;
    double animSpeed = 1.0;
    enum double animDuration = 8.0; // seconds for the full open/close cycle
    double lastFrameTime = glfwGetTime();

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
        if (dcad_gui_begin("3D Viewport", fixedPaneFlags))
        {
            float x, y, w, h;
            dcad_gui_get_window_pos(&x, &y);
            dcad_gui_get_window_size(&w, &h);
            immutable imgW = w - 16 > 16 ? w - 16 : 16;
            immutable imgH = h - 48 > 16 ? h - 48 : 16;

            // Camera interaction: use IO mouse delta while the window is hovered.
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

            // Mesh quality slider: re-mesh the current shape when it changes.
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

            // Animation transport, only shown for scripts that opt in.
            if (hasAnimation)
            {
                dcad_gui_separator();
                dcad_gui_text_colored("ASSEMBLY ANIMATION".toStringz,
                                      0.38f, 0.35f, 0.61f, 1);
                if (dcad_gui_button(animPlaying ? "Pause" : "Play"))
                    animPlaying = !animPlaying;
                dcad_gui_same_line();
                if (dcad_gui_button("Restart"))
                {
                    animTime = 0;
                    animPlaying = true;
                }

                float speedF = cast(float) animSpeed;
                if (dcad_gui_slider_float("Speed", &speedF, 0.1f, 3.0f) != 0)
                    animSpeed = speedF;

                float timeF = cast(float)(animTime / animDuration);
                if (dcad_gui_slider_float("Timeline", &timeF, 0f, 1f) != 0)
                    animTime = timeF * animDuration;
            }

            // Advance the animation. Only a translation uniform is uploaded;
            // the OCCT meshes stay static for the whole playback.
            immutable now = glfwGetTime();
            if (hasAnimation)
            {
                if (animPlaying)
                    animTime += (now - lastFrameTime) * animSpeed;
                while (animTime > animDuration)
                    animTime -= animDuration;
                viewport.setOffsets(host.animPose(animTime / animDuration,
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
