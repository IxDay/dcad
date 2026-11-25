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
#include <cstdio>
#include <string>
#include <vector>
#include <unordered_map>
#include <algorithm>

#ifdef _WIN32
// The Windows SDK's GL/gl.h relies on WINGDIAPI/APIENTRY from windows.h.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif
#ifdef __APPLE__
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl.h>
#else
#include <GL/gl.h>
#endif
#ifdef _WIN32
// The Windows SDK ships OpenGL 1.1 headers; ImGui's embedded loader provides
// the rest, but GL_CLAMP_TO_EDGE is needed by the icon texture code here.
#ifndef GL_CLAMP_TO_EDGE
#define GL_CLAMP_TO_EDGE 0x812F
#endif
#endif
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "imgui.h"
#include "imgui_internal.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_opengl3.h"
#include "TextEditor.h"

struct GLFWwindow;

/* --------------------------------------------------------------------------
 * ImGui lifecycle
 * -------------------------------------------------------------------------- */

static ImFont* addFontFromAsset(ImGuiIO& io, const char* path, float size,
                                const ImWchar* ranges)
{
    FILE* f = std::fopen(path, "rb");
    if (!f) return nullptr;
    std::fclose(f);
    return io.Fonts->AddFontFromFileTTF(path, size, nullptr, ranges);
}

static void loadGuiFont(ImGuiIO& io)
{
    // Text uses the monospace UI font; icons are PNG textures.
    static ImWchar textRange[] = {0x0020, 0x00FF, 0};

    char homeFont[1024] = {0};
    if (const char* home = std::getenv("HOME"))
        std::snprintf(homeFont, sizeof(homeFont),
                      "%s/Library/Fonts/mesloLGS_NF_regular.ttf", home);

    bool haveTextFont = false;
    const char* textCandidates[] = {
        "gui/assets/MesloLGS_NF_Regular.ttf",
        homeFont,
    };
    for (const char* path : textCandidates)
    {
        if (!path || !*path) continue;
        if (addFontFromAsset(io, path, 15.0f, textRange))
        {
            haveTextFont = true;
            break;
        }
    }
    if (!haveTextFont) io.Fonts->AddFontDefault();
}

/* --------------------------------------------------------------------------
 * Icon textures. These PNGs are rasterised from VS Code's own assets (the
 * theme-seti light file icons and codicons) by
 * gui/assets/extract-vscode-icons.swift. Keeping them as textures instead of
 * private-use font glyphs means the sidebar and toolbar look exactly like
 * VS Code, without depending on any locally installed font.
 * -------------------------------------------------------------------------- */

static std::unordered_map<std::string, ImTextureID> g_iconTextures;

extern "C" void* dcad_gui_icon(const char* name)
{
    if (!name || !*name) return nullptr;

    auto found = g_iconTextures.find(name);
    if (found != g_iconTextures.end())
        return reinterpret_cast<void*>(found->second);

    char path[512];
    std::snprintf(path, sizeof(path), "gui/assets/icons/%s.png", name);

    int width = 0, height = 0, channels = 0;
    unsigned char* pixels = stbi_load(path, &width, &height, &channels, 4);
    if (!pixels)
    {
        std::fprintf(stderr, "gui icon not found: %s\n", path);
        g_iconTextures[name] = 0;
        return nullptr;
    }

    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glBindTexture(GL_TEXTURE_2D, 0);
    stbi_image_free(pixels);

    ImTextureID id = static_cast<ImTextureID>(texture);
    g_iconTextures[name] = id;
    return reinterpret_cast<void*>(id);
}

static void releaseIcons()
{
    for (const auto& entry : g_iconTextures)
    {
        GLuint texture = static_cast<GLuint>(entry.second);
        if (texture) glDeleteTextures(1, &texture);
    }
    g_iconTextures.clear();
}

extern "C" void dcad_gui_init(void* window, const char* glslVersion)
{
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    loadGuiFont(io);

    ImGui_ImplGlfw_InitForOpenGL(static_cast<GLFWwindow*>(window), true);
    ImGui_ImplOpenGL3_Init(glslVersion ? glslVersion : "#version 150");
}

/* --------------------------------------------------------------------------
 * The user's Visual Studio Code theme: Base16 Default Light, translated to
 * ImGui. Sidebar background uses the user's #f9f9f9 override.
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

    // VS Code / Base16: small radii, thin borders, compact controls.
    s.WindowRounding = 2.0f;
    s.ChildRounding = 2.0f;
    s.PopupRounding = 3.0f;
    s.FrameRounding = 2.0f;
    s.ScrollbarRounding = 2.0f;
    s.GrabRounding = 2.0f;
    s.TabRounding = 2.0f;

    s.WindowPadding = ImVec2(10, 8);
    s.FramePadding = ImVec2(8, 4);
    s.ItemSpacing = ImVec2(6, 4);
    s.ItemInnerSpacing = ImVec2(6, 4);
    s.IndentSpacing = 16.0f;
    s.ScrollbarSize = 12.0f;
    s.GrabMinSize = 10.0f;
    s.WindowBorderSize = 1.0f;
    s.FrameBorderSize = 1.0f;
    s.PopupBorderSize = 1.0f;

    // Base16 Default Light, with the user's sideBar.background override.
    ImVec4* c = s.Colors;
    c[ImGuiCol_Text]                   = broc(0x383838);
    c[ImGuiCol_TextDisabled]           = broc(0xb8b8b8);
    c[ImGuiCol_WindowBg]               = broc(0xf8f8f8);
    c[ImGuiCol_ChildBg]                = broc(0xf9f9f9);
    c[ImGuiCol_PopupBg]                = broc(0xf8f8f8);
    c[ImGuiCol_Border]                 = broc(0xe8e8e8);
    c[ImGuiCol_BorderShadow]           = broc(0x000000, 0.04f);
    c[ImGuiCol_FrameBg]                = broc(0xf8f8f8);
    c[ImGuiCol_FrameBgHovered]         = broc(0xe8e8e8);
    c[ImGuiCol_FrameBgActive]          = broc(0xd8d8d8);
    c[ImGuiCol_TitleBg]                = broc(0xe8e8e8);
    c[ImGuiCol_TitleBgActive]          = broc(0xd8d8d8);
    c[ImGuiCol_TitleBgCollapsed]       = broc(0xe8e8e8);
    c[ImGuiCol_MenuBarBg]              = broc(0xf8f8f8);
    c[ImGuiCol_ScrollbarBg]            = broc(0xf8f8f8);
    c[ImGuiCol_ScrollbarGrab]          = broc(0xd8d8d8);
    c[ImGuiCol_ScrollbarGrabHovered]   = broc(0xb8b8b8);
    c[ImGuiCol_ScrollbarGrabActive]    = broc(0x585858);
    c[ImGuiCol_CheckMark]              = broc(0x7cafc2);
    c[ImGuiCol_SliderGrab]             = broc(0x7cafc2);
    c[ImGuiCol_SliderGrabActive]       = broc(0x585858);
    c[ImGuiCol_Button]                 = broc(0x7cafc2);
    c[ImGuiCol_ButtonHovered]          = broc(0xd8d8d8);
    c[ImGuiCol_ButtonActive]           = broc(0xb8b8b8);
    c[ImGuiCol_Header]                 = broc(0xe8e8e8);
    c[ImGuiCol_HeaderHovered]          = broc(0xd8d8d8);
    c[ImGuiCol_HeaderActive]           = broc(0x7cafc2, 0.45f);
    c[ImGuiCol_Separator]              = broc(0xe8e8e8);
    c[ImGuiCol_SeparatorHovered]       = broc(0x7cafc2);
    c[ImGuiCol_SeparatorActive]        = broc(0x585858);
    c[ImGuiCol_ResizeGrip]             = broc(0xd8d8d8);
    c[ImGuiCol_ResizeGripHovered]      = broc(0x7cafc2);
    c[ImGuiCol_ResizeGripActive]       = broc(0x585858);
    c[ImGuiCol_Tab]                    = broc(0xe8e8e8);
    c[ImGuiCol_TabHovered]             = broc(0xd8d8d8);
    c[ImGuiCol_TabSelected]            = broc(0xf8f8f8);
    c[ImGuiCol_TabSelectedOverline]    = broc(0x7cafc2);
    c[ImGuiCol_TabDimmed]              = broc(0xf0f0f0);
    c[ImGuiCol_TabDimmedSelected]      = broc(0xe8e8e8);
    c[ImGuiCol_DockingPreview]         = broc(0x7cafc2, 0.4f);
    c[ImGuiCol_DockingEmptyBg]         = broc(0xf8f8f8);
    c[ImGuiCol_TableHeaderBg]          = broc(0xe8e8e8);
    c[ImGuiCol_TableBorderStrong]      = broc(0xd8d8d8);
    c[ImGuiCol_TableBorderLight]       = broc(0xe8e8e8);
    c[ImGuiCol_TableRowBg]             = broc(0xf8f8f8);
    c[ImGuiCol_TableRowBgAlt]          = broc(0xf0f0f0);
    c[ImGuiCol_TextSelectedBg]         = broc(0xd8d8d8);
    c[ImGuiCol_DragDropTarget]         = broc(0x7cafc2);
    c[ImGuiCol_NavCursor]              = broc(0x7cafc2);
    c[ImGuiCol_TextLink]               = broc(0x7cafc2);
    c[ImGuiCol_TreeLines]              = broc(0xd8d8d8);
    c[ImGuiCol_NavWindowingHighlight]  = broc(0x7cafc2, 0.6f);
    c[ImGuiCol_NavWindowingDimBg]      = broc(0x000000, 0.1f);
    c[ImGuiCol_ModalWindowDimBg]       = broc(0x000000, 0.25f);
}

/* --------------------------------------------------------------------------
 * Zed-like dark theme: near-black panes, cool grey chrome, blue-violet accent,
 * small radii and tight spacing.
 * -------------------------------------------------------------------------- */

extern "C" void dcad_gui_apply_zed_theme(void)
{
    ImGui::StyleColorsDark();
    ImGuiStyle& s = ImGui::GetStyle();

    s.WindowRounding = 8.0f;
    s.ChildRounding = 6.0f;
    s.PopupRounding = 6.0f;
    s.FrameRounding = 5.0f;
    s.ScrollbarRounding = 5.0f;
    s.GrabRounding = 4.0f;
    s.TabRounding = 5.0f;

    s.WindowPadding = ImVec2(10, 8);
    s.FramePadding = ImVec2(8, 5);
    s.ItemSpacing = ImVec2(6, 4);
    s.ItemInnerSpacing = ImVec2(5, 3);
    s.IndentSpacing = 14.0f;
    s.ScrollbarSize = 10.0f;
    s.GrabMinSize = 10.0f;
    s.WindowBorderSize = 1.0f;
    s.FrameBorderSize = 0.0f;
    s.PopupBorderSize = 1.0f;

    ImVec4* c = s.Colors;
    c[ImGuiCol_Text]                   = broc(0xd6dade);
    c[ImGuiCol_TextDisabled]           = broc(0x7d858d);
    c[ImGuiCol_WindowBg]               = broc(0x1b1d1f);
    c[ImGuiCol_ChildBg]                = broc(0x202325);
    c[ImGuiCol_PopupBg]                = broc(0x25292d);
    c[ImGuiCol_Border]                 = broc(0x30363c);
    c[ImGuiCol_BorderShadow]           = broc(0x000000, 0.2f);
    c[ImGuiCol_FrameBg]                = broc(0x25292d);
    c[ImGuiCol_FrameBgHovered]         = broc(0x30363c);
    c[ImGuiCol_FrameBgActive]          = broc(0x3a424a);
    c[ImGuiCol_TitleBg]                = broc(0x202325);
    c[ImGuiCol_TitleBgActive]          = broc(0x25292d);
    c[ImGuiCol_TitleBgCollapsed]       = broc(0x202325);
    c[ImGuiCol_MenuBarBg]              = broc(0x202325);
    c[ImGuiCol_ScrollbarBg]            = broc(0x202325);
    c[ImGuiCol_ScrollbarGrab]          = broc(0x3a424a);
    c[ImGuiCol_ScrollbarGrabHovered]   = broc(0x4a5560);
    c[ImGuiCol_ScrollbarGrabActive]    = broc(0x5c6bc0);
    c[ImGuiCol_CheckMark]              = broc(0x8b9bff);
    c[ImGuiCol_SliderGrab]             = broc(0x8b9bff);
    c[ImGuiCol_SliderGrabActive]       = broc(0xa5b2ff);
    c[ImGuiCol_Button]                 = broc(0x262b30);
    c[ImGuiCol_ButtonHovered]          = broc(0x333b43);
    c[ImGuiCol_ButtonActive]           = broc(0x3d4752);
    c[ImGuiCol_Header]                 = broc(0x2b3137);
    c[ImGuiCol_HeaderHovered]          = broc(0x353d45);
    c[ImGuiCol_HeaderActive]           = broc(0x465263);
    c[ImGuiCol_Separator]              = broc(0x30363c);
    c[ImGuiCol_SeparatorHovered]       = broc(0x8b9bff);
    c[ImGuiCol_SeparatorActive]        = broc(0xa5b2ff);
    c[ImGuiCol_ResizeGrip]             = broc(0x3a424a);
    c[ImGuiCol_ResizeGripHovered]      = broc(0x8b9bff);
    c[ImGuiCol_ResizeGripActive]       = broc(0xa5b2ff);
    c[ImGuiCol_Tab]                    = broc(0x25292d);
    c[ImGuiCol_TabHovered]             = broc(0x353d45);
    c[ImGuiCol_TabSelected]            = broc(0x343b42);
    c[ImGuiCol_TabSelectedOverline]    = broc(0x8b9bff);
    c[ImGuiCol_TabDimmed]              = broc(0x202325);
    c[ImGuiCol_TabDimmedSelected]      = broc(0x2b3137);
    c[ImGuiCol_DockingPreview]         = broc(0x8b9bff, 0.5f);
    c[ImGuiCol_DockingEmptyBg]         = broc(0x1b1d1f);
    c[ImGuiCol_TableHeaderBg]          = broc(0x25292d);
    c[ImGuiCol_TableBorderStrong]      = broc(0x30363c);
    c[ImGuiCol_TableBorderLight]       = broc(0x272c30);
    c[ImGuiCol_TableRowBg]             = broc(0x1b1d1f);
    c[ImGuiCol_TableRowBgAlt]          = broc(0x202325);
    c[ImGuiCol_TextSelectedBg]         = broc(0x4c6ef5, 0.35f);
    c[ImGuiCol_DragDropTarget]         = broc(0x8b9bff);
    c[ImGuiCol_NavCursor]              = broc(0x8b9bff);
    c[ImGuiCol_TextLink]               = broc(0x8b9bff);
    c[ImGuiCol_TreeLines]              = broc(0x30363c);
    c[ImGuiCol_NavWindowingHighlight]  = broc(0x8b9bff, 0.7f);
    c[ImGuiCol_NavWindowingDimBg]      = broc(0x000000, 0.4f);
    c[ImGuiCol_ModalWindowDimBg]       = broc(0x000000, 0.5f);
}

extern "C" void dcad_gui_shutdown(void)
{
    releaseIcons();
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
extern "C" void dcad_gui_get_cursor_screen_pos(float* x, float* y)
{
    ImVec2 p = ImGui::GetCursorScreenPos(); *x = p.x; *y = p.y;
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
    // Base16 Light button.foreground is #181818 on the blue button background.
    ImGui::PushStyleColor(ImGuiCol_Text, broc(0x181818));
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8, 4));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 2.0f);
    bool pressed = ImGui::Button(label);
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor();
    return pressed ? 1 : 0;
}
extern "C" void dcad_gui_set_item_tooltip(const char* text)
{
    if (text && ImGui::IsItemHovered())
        ImGui::SetTooltip("%s", text);
}
extern "C" void dcad_gui_same_line(void) { ImGui::SameLine(); }
extern "C" void dcad_gui_align_text_to_frame_padding(void)
{
    ImGui::AlignTextToFramePadding();
}
extern "C" float dcad_gui_content_region_avail_x(void)
{
    return ImGui::GetContentRegionAvail().x;
}
extern "C" void dcad_gui_progress_bar(float fraction, float w, float h,
                                      const char* overlay)
{
    ImGui::ProgressBar(fraction < 0.0f ? 0.0f : fraction > 1.0f ? 1.0f : fraction,
                       ImVec2(w, h), overlay);
}
extern "C" void dcad_gui_separator(void) { ImGui::Separator(); }
extern "C" void dcad_gui_vertical_separator(void)
{
    ImGui::SeparatorEx(ImGuiSeparatorFlags_Vertical);
}
extern "C" void dcad_gui_spacing(void) { ImGui::Spacing(); }

extern "C" void dcad_gui_image(void* texID, float w, float h)
{
    // OpenGL FBO textures are bottom-up, ImGui's image UVs are top-down.
    // Flip V so the model is not displayed upside down.
    ImGui::Image(ImTextureRef(static_cast<ImTextureID>(reinterpret_cast<uintptr_t>(texID))),
                 ImVec2(w, h), ImVec2(0, 1), ImVec2(1, 0));
}

static ImTextureID iconTexture(void* texID)
{
    return static_cast<ImTextureID>(reinterpret_cast<uintptr_t>(texID));
}

extern "C" void dcad_gui_icon_image(void* texID, float w, float h)
{
    if (!texID) return;
    ImGui::Image(ImTextureRef(iconTexture(texID)), ImVec2(w, h));
}

extern "C" int dcad_gui_icon_button(const char* id, void* texID, float size)
{
    if (!texID) return dcad_gui_button(id);

    // VS Code toolbar buttons have no background at rest, only on hover.
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, broc(0xd8d8d8));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, broc(0x7cafc2, 0.45f));
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(2, 2));
    bool pressed = ImGui::ImageButton(id, ImTextureRef(iconTexture(texID)),
                                      ImVec2(size, size));
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(3);
    return pressed ? 1 : 0;
}

extern "C" int dcad_gui_toggle_icon_button(const char* id, void* texID,
                                            void* checkTex, float size, int active)
{
    bool pressed = dcad_gui_icon_button(id, texID, size) != 0;
    if (active && checkTex)
    {
        ImVec2 hi = ImGui::GetItemRectMax();
        float s = size * 0.42f;
        ImGui::GetWindowDrawList()->AddImage(
            ImTextureRef(iconTexture(checkTex)),
            ImVec2(hi.x - s - 1.0f, hi.y - s - 1.0f),
            ImVec2(hi.x - 1.0f, hi.y - 1.0f));
    }
    return pressed ? 1 : 0;
}

extern "C" void dcad_gui_set_cursor_screen_pos(float x, float y)
{
    ImGui::SetCursorScreenPos(ImVec2(x, y));
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

extern "C" int dcad_gui_tree_node(const char* label, int* open)
{
    ImGui::SetNextItemOpen(*open != 0, ImGuiCond_Always);
    bool isOpen = ImGui::TreeNodeEx(label,
        ImGuiTreeNodeFlags_OpenOnArrow | ImGuiTreeNodeFlags_SpanAvailWidth,
        "%s", label);
    *open = isOpen ? 1 : 0;
    return isOpen ? 1 : 0;
}
extern "C" void dcad_gui_tree_pop(void) { ImGui::TreePop(); }
extern "C" int dcad_gui_selectable(const char* label, int selected)
{
    return ImGui::Selectable(label, selected != 0) ? 1 : 0;
}

extern "C" int dcad_gui_slider_float(const char* label, float* v, float vmin, float vmax)
{
    return ImGui::SliderFloat(label, v, vmin, vmax) ? 1 : 0;
}
extern "C" int dcad_gui_checkbox(const char* label, int* v)
{
    bool value = *v != 0;
    bool changed = ImGui::Checkbox(label, &value);
    *v = value ? 1 : 0;
    return changed ? 1 : 0;
}
extern "C" int dcad_gui_input_float(const char* label, float* v, float step)
{
    return ImGui::InputFloat(label, v, step, 0.0f, "%.2f") ? 1 : 0;
}
extern "C" int dcad_gui_input_int(const char* label, int* v, int step)
{
    return ImGui::InputInt(label, v, step) ? 1 : 0;
}
extern "C" void dcad_gui_set_next_item_width(float w) { ImGui::SetNextItemWidth(w); }

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
extern "C" void dcad_gui_get_mouse_pos(float* x, float* y)
{
    ImVec2 p = ImGui::GetMousePos(); *x = p.x; *y = p.y;
}
extern "C" void dcad_gui_get_item_rect(float* x0, float* y0, float* x1, float* y1)
{
    ImVec2 lo = ImGui::GetItemRectMin(), hi = ImGui::GetItemRectMax();
    *x0 = lo.x; *y0 = lo.y; *x1 = hi.x; *y1 = hi.y;
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

static TextEditor::LanguageDefinition dLanguageDefinition()
{
    // ImGuiColorTextEdit has no D grammar; C++ is the closest built-in, so
    // extend it with D keywords, built-in types and @attribute highlighting.
    auto lang = TextEditor::LanguageDefinition::CPlusPlus();
    lang.mName = "D";
    const char* keywords[] = {
        "abstract", "alias", "align", "asm", "auto", "body", "cast", "class",
        "const", "continue", "debug", "delegate", "deprecated", "do", "else",
        "enum", "export", "extern", "final", "finally", "foreach", "foreach_reverse",
        "for", "function", "goto", "if", "immutable", "import", "in", "inout",
        "interface", "invariant", "is", "lazy", "mixin", "module", "new", "nothrow",
        "out", "override", "package", "pragma", "private", "protected", "public",
        "pure", "ref", "return", "scope", "shared", "static", "struct", "super",
        "switch", "synchronized", "template", "this", "throw", "try", "typedef",
        "typeof", "union", "unittest", "version", "while", "with",
        "bool", "byte", "cdouble", "cent", "cfloat", "char", "creal", "dchar",
        "double", "float", "idouble", "ifloat", "int", "ireal", "long", "real",
        "short", "size_t", "string", "ubyte", "ucent", "uint", "ulong", "ushort",
        "void", "wchar"
    };
    for (const char* keyword : keywords)
        lang.mKeywords.insert(keyword);
    lang.mTokenRegexStrings.push_back(
        {std::string("@[A-Za-z_][A-Za-z0-9_]*"),
         TextEditor::PaletteIndex::Preprocessor});
    return lang;
}

extern "C" void* dcad_textedit_new(void)
{
    TextEditor* ed = new TextEditor();
    ed->SetLanguageDefinition(dLanguageDefinition());
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
    // Base16 Default Light token colours, mapped to ImGuiColorTextEdit.
    set(PI::Default,           0x383838);
    set(PI::Keyword,           0xba8baf);
    set(PI::Number,            0xdc9656);
    set(PI::String,            0xa1b56c);
    set(PI::CharLiteral,       0xdc9656);
    set(PI::Punctuation,       0x383838);
    set(PI::Preprocessor,      0x7cafc2);
    set(PI::Identifier,        0x383838);
    set(PI::KnownIdentifier,   0x7cafc2);
    set(PI::PreprocIdentifier, 0xba8baf);
    set(PI::Comment,           0xb8b8b8);
    set(PI::MultiLineComment,  0xb8b8b8);
    set(PI::Background,        0xf8f8f8);
    set(PI::Cursor,            0x383838);
    set(PI::Selection,         0xd8d8d8);
    set(PI::ErrorMarker,       0xab4642, 0xa0);
    set(PI::Breakpoint,        0xf7ca88, 0x80);
    set(PI::LineNumber,        0xb8b8b8);
    set(PI::CurrentLineFill,   0xe8e8e8, 0x80);
    set(PI::CurrentLineFillInactive, 0xf8f8f8, 0x60);
    set(PI::CurrentLineEdge,   0xe8e8e8, 0x80);
    static_cast<TextEditor*>(ed)->SetPalette(p);
}

extern "C" void dcad_textedit_set_zed_palette(void* ed)
{
    using PI = TextEditor::PaletteIndex;
    auto p = TextEditor::GetDarkPalette();
    auto set = [&p](PI i, unsigned int rgb, unsigned int a = 0xff) {
        p[static_cast<size_t>(i)] =
            IM_COL32((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff, a);
    };
    set(PI::Default,           0xd6dade);
    set(PI::Keyword,           0x82aaff);
    set(PI::Number,            0xf78c6b);
    set(PI::String,            0xc3e88d);
    set(PI::CharLiteral,       0xc3e88d);
    set(PI::Punctuation,       0x9aa3ab);
    set(PI::Preprocessor,      0x82aaff);
    set(PI::Identifier,        0xd6dade);
    set(PI::KnownIdentifier,   0x8b9bff);
    set(PI::PreprocIdentifier, 0xc792ea);
    set(PI::Comment,           0x6c7680);
    set(PI::MultiLineComment,  0x6c7680);
    set(PI::Background,        0x1b1d1f);
    set(PI::Cursor,            0x8b9bff);
    set(PI::Selection,         0x4c6ef5, 0x45);
    set(PI::ErrorMarker,       0xff6b6b, 0xa0);
    set(PI::Breakpoint,        0xf5b97a, 0x80);
    set(PI::LineNumber,        0x5f6973);
    set(PI::CurrentLineFill,   0x25292d, 0x80);
    set(PI::CurrentLineFillInactive, 0x25292d, 0x40);
    set(PI::CurrentLineEdge,   0x343b42, 0x80);
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
