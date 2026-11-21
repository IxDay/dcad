/*
 * dcad GUI shim -- extern "C" wrappers around Dear ImGui (docking branch),
 * its GLFW/OpenGL3 backends, ImGuiColorTextEdit, and OCCT mesh extraction.
 *
 * Dear ImGui and TextEditor are C++ APIs, so -- exactly as with OCCT in the
 * core library -- D cannot call them directly. Every function here has a
 * plain C signature; all C++ types stay inside this translation unit.
 */
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <algorithm>

#include "imgui.h"
#include "imgui_internal.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_opengl3.h"
#include "TextEditor.h"

struct GLFWwindow;

/* --------------------------------------------------------------------------
 * ImGui lifecycle
 * -------------------------------------------------------------------------- */

extern "C" void dcad_gui_init(void* window, const char* glslVersion)
{
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;

    ImGui_ImplGlfw_InitForOpenGL(static_cast<GLFWwindow*>(window), true);
    ImGui_ImplOpenGL3_Init(glslVersion ? glslVersion : "#version 150");
}

/* --------------------------------------------------------------------------
 * Brocanth-ui "original" theme, light variant, translated to ImGui.
 * Purple brand #625afa / #9d97ff, cool greys #f6f8fa -> #1a1b25, body text
 * #414552, 4/6/8/10px radii, 32px controls, two-layer shadow.
 * -------------------------------------------------------------------------- */

static ImVec4 broc(unsigned int rgb, float a = 1.0f)
{
    return ImVec4(static_cast<float>((rgb >> 16) & 0xFF) / 255.0f,
                  static_cast<float>((rgb >> 8) & 0xFF) / 255.0f,
                  static_cast<float>(rgb & 0xFF) / 255.0f, a);
}

extern "C" void dcad_gui_apply_light_theme(void)
{
    ImGui::StyleColorsLight();
    ImGuiStyle& s = ImGui::GetStyle();

    // Tight radii: 4 (small) / 6 (controls) / 8 (children) / 10 (windows).
    s.WindowRounding = 10.0f;
    s.ChildRounding = 8.0f;
    s.PopupRounding = 8.0f;
    s.FrameRounding = 6.0f;
    s.ScrollbarRounding = 6.0f;
    s.GrabRounding = 6.0f;
    s.TabRounding = 6.0f;

    // 32px controls with compact 4/6/8/10 spacing grid.
    s.WindowPadding = ImVec2(10, 10);
    s.FramePadding = ImVec2(10, 9);
    s.ItemSpacing = ImVec2(8, 6);
    s.ItemInnerSpacing = ImVec2(6, 4);
    s.IndentSpacing = 16.0f;
    s.ScrollbarSize = 12.0f;
    s.GrabMinSize = 12.0f;
    s.WindowBorderSize = 1.0f;
    s.FrameBorderSize = 1.0f;
    s.PopupBorderSize = 1.0f;

    ImVec4* c = s.Colors;
    c[ImGuiCol_Text]                   = broc(0x414552);
    c[ImGuiCol_TextDisabled]           = broc(0x8b8f9a);
    c[ImGuiCol_WindowBg]               = broc(0xffffff);
    c[ImGuiCol_ChildBg]                = broc(0xf6f8fa);
    c[ImGuiCol_PopupBg]                = broc(0xffffff);
    c[ImGuiCol_Border]                 = broc(0xd5dbe1);
    c[ImGuiCol_BorderShadow]           = broc(0x1a1b25, 0.05f);
    c[ImGuiCol_FrameBg]                = broc(0xf6f8fa);
    c[ImGuiCol_FrameBgHovered]         = broc(0xedeaff);
    c[ImGuiCol_FrameBgActive]          = broc(0xe0dbff);
    c[ImGuiCol_TitleBg]                = broc(0xf6f8fa);
    c[ImGuiCol_TitleBgActive]          = broc(0xece9ff);
    c[ImGuiCol_TitleBgCollapsed]       = broc(0xf6f8fa);
    c[ImGuiCol_MenuBarBg]              = broc(0xf6f8fa);
    c[ImGuiCol_ScrollbarBg]            = broc(0xf6f8fa);
    c[ImGuiCol_ScrollbarGrab]          = broc(0xc9ced6);
    c[ImGuiCol_ScrollbarGrabHovered]   = broc(0xaeb5c0);
    c[ImGuiCol_ScrollbarGrabActive]    = broc(0x9d97ff);
    c[ImGuiCol_CheckMark]              = broc(0x625afa);
    c[ImGuiCol_SliderGrab]             = broc(0x625afa);
    c[ImGuiCol_SliderGrabActive]       = broc(0x4f46e5);
    c[ImGuiCol_Button]                 = broc(0x9d97ff);
    c[ImGuiCol_ButtonHovered]          = broc(0xb49cfc);
    c[ImGuiCol_ButtonActive]           = broc(0x8a83ef);
    c[ImGuiCol_Header]                 = broc(0xf0edff);
    c[ImGuiCol_HeaderHovered]          = broc(0xe4e0ff);
    c[ImGuiCol_HeaderActive]           = broc(0x9d97ff);
    c[ImGuiCol_Separator]              = broc(0xd5dbe1);
    c[ImGuiCol_SeparatorHovered]       = broc(0x9d97ff);
    c[ImGuiCol_SeparatorActive]        = broc(0x625afa);
    c[ImGuiCol_ResizeGrip]             = broc(0xc9ced6);
    c[ImGuiCol_ResizeGripHovered]      = broc(0x9d97ff);
    c[ImGuiCol_ResizeGripActive]       = broc(0x625afa);
    c[ImGuiCol_Tab]                    = broc(0xf6f8fa);
    c[ImGuiCol_TabHovered]             = broc(0xe4e0ff);
    c[ImGuiCol_TabSelected]            = broc(0x9d97ff);
    c[ImGuiCol_TabSelectedOverline]    = broc(0x625afa);
    c[ImGuiCol_TabDimmed]              = broc(0xf0f2f5);
    c[ImGuiCol_TabDimmedSelected]      = broc(0xded9ff);
    c[ImGuiCol_DockingPreview]         = broc(0x9d97ff, 0.5f);
    c[ImGuiCol_DockingEmptyBg]         = broc(0xf6f8fa);
    c[ImGuiCol_TableHeaderBg]          = broc(0xf6f8fa);
    c[ImGuiCol_TableBorderStrong]      = broc(0xd5dbe1);
    c[ImGuiCol_TableBorderLight]       = broc(0xe8ebef);
    c[ImGuiCol_TableRowBg]             = broc(0xffffff);
    c[ImGuiCol_TableRowBgAlt]          = broc(0xf6f8fa);
    c[ImGuiCol_TextSelectedBg]         = broc(0x9d97ff, 0.35f);
    c[ImGuiCol_DragDropTarget]         = broc(0x625afa);
    c[ImGuiCol_NavCursor]              = broc(0x625afa);
    c[ImGuiCol_TextLink]               = broc(0x625afa);
    c[ImGuiCol_TreeLines]              = broc(0xd5dbe1);
    c[ImGuiCol_NavWindowingHighlight]  = broc(0x625afa, 0.7f);
    c[ImGuiCol_NavWindowingDimBg]      = broc(0x1a1b25, 0.2f);
    c[ImGuiCol_ModalWindowDimBg]       = broc(0x1a1b25, 0.35f);
}

extern "C" void dcad_gui_shutdown(void)
{
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
}

extern "C" void dcad_gui_new_frame(void)
{
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    ImGui::NewFrame();
}

extern "C" void dcad_gui_render(void)
{
    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

extern "C" void dcad_gui_dockspace(void)
{
    ImGui::DockSpaceOverViewport(0, ImGui::GetMainViewport(),
                                 ImGuiDockNodeFlags_PassthruCentralNode);
}

/* --------------------------------------------------------------------------
 * Windows and widgets
 * -------------------------------------------------------------------------- */

extern "C" int dcad_gui_begin(const char* name, int flags)
{
    return ImGui::Begin(name, nullptr, static_cast<ImGuiWindowFlags>(flags)) ? 1 : 0;
}

extern "C" void dcad_gui_end(void) { ImGui::End(); }

extern "C" void dcad_gui_set_next_window_pos(float x, float y, int cond)
{
    ImGui::SetNextWindowPos(ImVec2(x, y), static_cast<ImGuiCond>(cond));
}
extern "C" void dcad_gui_set_next_window_size(float w, float h, int cond)
{
    ImGui::SetNextWindowSize(ImVec2(w, h), static_cast<ImGuiCond>(cond));
}
extern "C" void dcad_gui_get_window_pos(float* x, float* y)
{
    ImVec2 p = ImGui::GetWindowPos(); *x = p.x; *y = p.y;
}
extern "C" void dcad_gui_get_window_size(float* w, float* h)
{
    ImVec2 s = ImGui::GetWindowSize(); *w = s.x; *h = s.y;
}
extern "C" void dcad_gui_get_viewport_size(float* w, float* h)
{
    ImVec2 s = ImGui::GetMainViewport()->Size; *w = s.x; *h = s.y;
}
extern "C" int dcad_gui_is_window_hovered(void)
{
    return ImGui::IsWindowHovered() ? 1 : 0;
}
extern "C" int dcad_gui_is_window_focused(void)
{
    return ImGui::IsWindowFocused() ? 1 : 0;
}

extern "C" void dcad_gui_text(const char* text) { ImGui::TextUnformatted(text); }
extern "C" void dcad_gui_text_wrapped(const char* text) { ImGui::TextWrapped("%s", text); }
extern "C" void dcad_gui_text_colored(const char* text, float r, float g, float b, float a)
{
    ImGui::TextColored(ImVec4(r, g, b, a), "%s", text);
}
extern "C" int dcad_gui_button(const char* label)
{
    // Brocanth uses anthracite text on its coloured buttons (5.3:1 contrast).
    ImGui::PushStyleColor(ImGuiCol_Text, broc(0x2b2f36));
    bool pressed = ImGui::Button(label);
    ImGui::PopStyleColor();
    return pressed ? 1 : 0;
}
extern "C" void dcad_gui_same_line(void) { ImGui::SameLine(); }
extern "C" void dcad_gui_separator(void) { ImGui::Separator(); }
extern "C" void dcad_gui_spacing(void) { ImGui::Spacing(); }

extern "C" void dcad_gui_image(void* texID, float w, float h)
{
    // OpenGL FBO textures are bottom-up, ImGui's image UVs are top-down.
    // Flip V so the model is not displayed upside down.
    ImGui::Image(ImTextureRef(static_cast<ImTextureID>(reinterpret_cast<uintptr_t>(texID))),
                 ImVec2(w, h), ImVec2(0, 1), ImVec2(1, 0));
}

extern "C" int dcad_gui_invisible_button(const char* id, float w, float h)
{
    return ImGui::InvisibleButton(id, ImVec2(w, h)) ? 1 : 0;
}
extern "C" int dcad_gui_is_item_active(void) { return ImGui::IsItemActive() ? 1 : 0; }
extern "C" int dcad_gui_is_item_hovered(void) { return ImGui::IsItemHovered() ? 1 : 0; }

extern "C" int dcad_gui_begin_child(const char* id, float w, float h, int flags)
{
    return ImGui::BeginChild(id, ImVec2(w, h), static_cast<ImGuiChildFlags>(flags)) ? 1 : 0;
}
extern "C" void dcad_gui_end_child(void) { ImGui::EndChild(); }

extern "C" int dcad_gui_begin_menu_bar(void) { return ImGui::BeginMenuBar() ? 1 : 0; }
extern "C" void dcad_gui_end_menu_bar(void) { ImGui::EndMenuBar(); }
extern "C" int dcad_gui_begin_menu(const char* label) { return ImGui::BeginMenu(label) ? 1 : 0; }
extern "C" void dcad_gui_end_menu(void) { ImGui::EndMenu(); }
extern "C" int dcad_gui_menu_item(const char* label, const char* shortcut, int selected, int enabled)
{
    return ImGui::MenuItem(label, shortcut, selected != 0, enabled != 0) ? 1 : 0;
}

extern "C" int dcad_gui_slider_float(const char* label, float* v, float vmin, float vmax)
{
    return ImGui::SliderFloat(label, v, vmin, vmax) ? 1 : 0;
}

/* --------------------------------------------------------------------------
 * Input state
 * -------------------------------------------------------------------------- */

extern "C" void dcad_gui_get_mouse_delta(float* x, float* y)
{
    ImVec2 d = ImGui::GetMouseDragDelta(0, 0.0f);
    *x = d.x; *y = d.y;
}
extern "C" void dcad_gui_get_io_mouse_delta(float* x, float* y)
{
    ImVec2 d = ImGui::GetIO().MouseDelta; *x = d.x; *y = d.y;
}
extern "C" float dcad_gui_get_mouse_wheel_y(void) { return ImGui::GetIO().MouseWheel; }
extern "C" int dcad_gui_mouse_down(int button)
{
    return ImGui::IsMouseDown(button) ? 1 : 0;
}
extern "C" int dcad_gui_key_chord_pressed(int keyChord)
{
    return ImGui::IsKeyChordPressed(static_cast<ImGuiKeyChord>(keyChord)) ? 1 : 0;
}
extern "C" int dcad_gui_mouse_clicked(int button)
{
    return ImGui::IsMouseClicked(button) ? 1 : 0;
}

/* --------------------------------------------------------------------------
 * ImGuiColorTextEdit
 * -------------------------------------------------------------------------- */

extern "C" void* dcad_textedit_new(void)
{
    TextEditor* ed = new TextEditor();
    ed->SetLanguageDefinition(TextEditor::LanguageDefinition::CPlusPlus());
    return ed;
}
extern "C" void dcad_textedit_free(void* ed) { delete static_cast<TextEditor*>(ed); }
extern "C" void dcad_textedit_set_light_palette(void* ed)
{
    using PI = TextEditor::PaletteIndex;
    auto p = TextEditor::GetLightPalette();
    auto set = [&p](PI i, unsigned int rgb, unsigned int a = 0xff) {
        p[static_cast<size_t>(i)] =
            IM_COL32((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff, a);
    };
    set(PI::Default,           0x414552);
    set(PI::Keyword,           0x625afa);
    set(PI::Number,            0xb45309);
    set(PI::String,            0x2e7d32);
    set(PI::CharLiteral,       0x2e7d32);
    set(PI::Punctuation,       0x4a4f5c);
    set(PI::Preprocessor,      0x0f766e);
    set(PI::Identifier,        0x1a1b25);
    set(PI::KnownIdentifier,   0x625afa);
    set(PI::PreprocIdentifier, 0xb14b8a);
    set(PI::Comment,           0x8b8f9a);
    set(PI::MultiLineComment,  0x8b8f9a);
    set(PI::Background,        0xffffff);
    set(PI::Cursor,            0x625afa);
    set(PI::Selection,         0x9d97ff, 0x47);
    set(PI::ErrorMarker,       0xdc2626, 0xa0);
    set(PI::Breakpoint,        0xf59e0b, 0x80);
    set(PI::LineNumber,        0x9aa0ab);
    set(PI::CurrentLineFill,   0xf6f8fa, 0x80);
    set(PI::CurrentLineFillInactive, 0xf6f8fa, 0x40);
    set(PI::CurrentLineEdge,   0xd5dbe1, 0x80);
    static_cast<TextEditor*>(ed)->SetPalette(p);
}

extern "C" void dcad_textedit_set_text(void* ed, const char* text)
{
    static_cast<TextEditor*>(ed)->SetText(text ? text : "");
}
extern "C" const char* dcad_textedit_get_text(void* ed)
{
    static thread_local std::string buffer;
    buffer = static_cast<TextEditor*>(ed)->GetText();
    return buffer.c_str();
}
extern "C" void dcad_textedit_render(void* ed, const char* title, float w, float h)
{
    static_cast<TextEditor*>(ed)->Render(title, ImVec2(w, h), false);
}
extern "C" int dcad_textedit_text_changed(void* ed)
{
    return static_cast<TextEditor*>(ed)->IsTextChanged() ? 1 : 0;
}
extern "C" void dcad_textedit_set_read_only(void* ed, int ro)
{
    static_cast<TextEditor*>(ed)->SetReadOnly(ro != 0);
}

/* --------------------------------------------------------------------------
 * OCCT mesh extraction
 * -------------------------------------------------------------------------- */

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_Triangle.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>
#include <TopAbs_ShapeEnum.hxx>

struct DcadMesh
{
    float* vertices;  // 9 floats per triangle (x,y,z x3)
    float* normals;   // 9 floats per triangle (nx,ny,nz x3)
    int triangles;
};

extern "C" int dcad_mesh_shape(const void* shapePtr, double deflection, DcadMesh* out)
{
    out->vertices = nullptr;
    out->normals = nullptr;
    out->triangles = 0;
    if (!shapePtr || !out) return -1;

    const TopoDS_Shape& shape = *static_cast<const TopoDS_Shape*>(shapePtr);
    if (shape.IsNull()) return -1;

    try {
        BRepMesh_IncrementalMesh mesher(shape, deflection, Standard_True);

        std::vector<float> verts;
        std::vector<float> norms;
        TopExp_Explorer exp(shape, TopAbs_FACE);
        for (; exp.More(); exp.Next())
        {
            TopoDS_Face face = TopoDS::Face(exp.Current());
            TopLoc_Location loc;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
            if (tri.IsNull()) continue;

            for (int i = 1; i <= tri->NbTriangles(); ++i)
            {
                int n1, n2, n3;
                tri->Triangle(i).Get(n1, n2, n3);
                gp_Pnt p1 = tri->Node(n1).Transformed(loc);
                gp_Pnt p2 = tri->Node(n2).Transformed(loc);
                gp_Pnt p3 = tri->Node(n3).Transformed(loc);
                if (face.Orientation() == TopAbs_REVERSED)
                    std::swap(p2, p3);

                gp_Vec e1(p1, p2), e2(p1, p3);
                gp_Vec n = e1.Crossed(e2);
                if (n.SquareMagnitude() < 1e-16) continue;
                n.Normalize();

                const gp_Pnt ps[3] = {p1, p2, p3};
                for (int k = 0; k < 3; ++k)
                {
                    verts.push_back(static_cast<float>(ps[k].X()));
                    verts.push_back(static_cast<float>(ps[k].Y()));
                    verts.push_back(static_cast<float>(ps[k].Z()));
                    norms.push_back(static_cast<float>(n.X()));
                    norms.push_back(static_cast<float>(n.Y()));
                    norms.push_back(static_cast<float>(n.Z()));
                }
            }
        }

        out->triangles = static_cast<int>(verts.size() / 9);
        if (out->triangles > 0)
        {
            out->vertices = static_cast<float*>(malloc(verts.size() * sizeof(float)));
            out->normals = static_cast<float*>(malloc(norms.size() * sizeof(float)));
            if (!out->vertices || !out->normals)
            {
                free(out->vertices); free(out->normals);
                out->vertices = out->normals = nullptr;
                out->triangles = 0;
                return -1;
            }
            memcpy(out->vertices, verts.data(), verts.size() * sizeof(float));
            memcpy(out->normals, norms.data(), norms.size() * sizeof(float));
        }
        return 0;
    }
    catch (...)
    {
        return -1;
    }
}

extern "C" void dcad_mesh_free(DcadMesh* mesh)
{
    if (!mesh) return;
    free(mesh->vertices);
    free(mesh->normals);
    mesh->vertices = nullptr;
    mesh->normals = nullptr;
    mesh->triangles = 0;
}
