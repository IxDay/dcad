/**
 * extern(C) declarations for the hand-written ImGui/TextEditor/mesh C++ shim.
 * See gui/shim/dcad_gui_shim.cpp. ImGui uses C++ linkage, so bindbc-imgui
 * (which targets cimgui's ig* API) is not used here.
 */
module gui.imgui;

// --- ImGui flags / enums ---------------------------------------------------
enum int windowFlagsNone = 0;
enum int windowFlagsNoTitleBar = 1 << 0;
enum int windowFlagsNoResize = 1 << 1;
enum int windowFlagsNoMove = 1 << 2;
enum int windowFlagsNoSavedSettings = 1 << 8;
enum int windowFlagsMenuBar = 1 << 10;
enum int windowFlagsNoDocking = 1 << 19;
enum int windowFlagsNoScrollbar = 1 << 3;
enum int windowFlagsNoScrollWithMouse = 1 << 4;

/// Both panes are locked into a fixed left/right split.
enum int fixedPaneFlags = windowFlagsNoTitleBar | windowFlagsNoMove |
                          windowFlagsNoResize | windowFlagsNoDocking |
                          windowFlagsNoSavedSettings;

/// The preview never scrolls: every control and the image fit vertically.
enum int viewportPaneFlags = fixedPaneFlags | windowFlagsNoScrollbar |
                             windowFlagsNoScrollWithMouse;

enum int condNone = 0;
enum int condAlways = 1 << 0;
enum int condOnce = 1 << 1;
enum int condFirstUseEver = 1 << 2;

enum int childFlagsNone = 0;
enum int childFlagsBorders = 1 << 0;

// ImGuiKey values (1.93): named keys start at 512.
enum int keyEnter = 525;
enum int keyF5 = 568;
enum int keyR = 555;
enum int modCtrl = 1 << 12; // Cmd on macOS

enum int mouseLeft = 0;
enum int mouseRight = 1;
enum int mouseMiddle = 2;

/// Opaque mesh returned by dcad_mesh_shape.
struct DcadMesh
{
    float* vertices; /// 9 floats per triangle
    float* normals;  /// 9 floats per triangle
    int triangles;
}

extern(C) nothrow @nogc
{
    // lifecycle
    void dcad_gui_init(void* window, const(char)* glslVersion);
    void dcad_gui_apply_light_theme();
    void dcad_gui_apply_zed_theme();
    void dcad_gui_shutdown();
    void dcad_gui_new_frame();
    void dcad_gui_render();
    void dcad_gui_dockspace();

    // windows / widgets
    int  dcad_gui_begin(const(char)* name, int flags);
    void dcad_gui_end();
    void dcad_gui_set_next_window_pos(float x, float y, int cond);
    void dcad_gui_set_next_window_size(float w, float h, int cond);
    void dcad_gui_get_window_pos(float* x, float* y);
    void dcad_gui_get_window_size(float* w, float* h);
    void dcad_gui_get_cursor_screen_pos(float* x, float* y);
    void dcad_gui_get_viewport_size(float* w, float* h);
    int  dcad_gui_is_window_hovered();
    int  dcad_gui_is_window_focused();
    void dcad_gui_text(const(char)* text);
    void dcad_gui_text_wrapped(const(char)* text);
    void dcad_gui_text_colored(const(char)* text, float r, float g, float b, float a);
    int  dcad_gui_button(const(char)* label);
    void dcad_gui_set_item_tooltip(const(char)* text);
    void dcad_gui_same_line();
    void dcad_gui_separator();
    void dcad_gui_vertical_separator();
    void dcad_gui_spacing();
    void dcad_gui_image(void* texID, float w, float h);
    int  dcad_gui_invisible_button(const(char)* id, float w, float h);
    int  dcad_gui_is_item_active();
    int  dcad_gui_is_item_hovered();
    int  dcad_gui_begin_child(const(char)* id, float w, float h, int flags);
    void dcad_gui_end_child();

    // menus
    int  dcad_gui_begin_menu_bar();
    void dcad_gui_end_menu_bar();
    int  dcad_gui_begin_menu(const(char)* label);
    void dcad_gui_end_menu();
    int  dcad_gui_menu_item(const(char)* label, const(char)* shortcut,
                            int selected, int enabled);
    int  dcad_gui_slider_float(const(char)* label, float* v,
                               float vmin, float vmax);
    int  dcad_gui_tree_node(const(char)* label, int* open);
    void dcad_gui_tree_pop();
    int  dcad_gui_selectable(const(char)* label, int selected);
    int  dcad_gui_checkbox(const(char)* label, int* v);
    int  dcad_gui_input_float(const(char)* label, float* v, float step);
    int  dcad_gui_input_int(const(char)* label, int* v, int step);
    void dcad_gui_set_next_item_width(float w);

    // input
    void  dcad_gui_get_mouse_delta(float* x, float* y);
    void  dcad_gui_get_io_mouse_delta(float* x, float* y);
    float dcad_gui_get_mouse_wheel_y();
    int   dcad_gui_mouse_down(int button);
    int   dcad_gui_mouse_clicked(int button);
    int   dcad_gui_key_chord_pressed(int keyChord);

    // TextEditor
    void*       dcad_textedit_new();
    void        dcad_textedit_free(void* ed);
    void        dcad_textedit_set_light_palette(void* ed);
    void        dcad_textedit_set_zed_palette(void* ed);
    void        dcad_textedit_set_text(void* ed, const(char)* text);
    const(char)* dcad_textedit_get_text(void* ed);
    void        dcad_textedit_render(void* ed, const(char)* title, float w, float h);
    int         dcad_textedit_text_changed(void* ed);

    // OCCT meshing
    int  dcad_mesh_shape(const(void)* shape, double deflection, DcadMesh* meshOut);
    void dcad_mesh_free(DcadMesh* mesh);
}
