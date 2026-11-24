/*
 * Native Windows menu bar for dcad-gui.
 *
 * GLFW creates a plain Win32 top-level window but exposes no menu API. We
 * attach a real HMENU to its HWND and subclass the window procedure just long
 * enough to intercept WM_COMMAND. Every other message is forwarded to GLFW's
 * original WndProc, so input and resize behaviour stay unchanged.
 */
#include <windows.h>

extern "C" void dcad_install_native_shader_menu(void* window, void* display,
                                                 void (*onSelect)(int));
extern "C" void dcad_native_menu_poll();

namespace
{
void (*g_onSelect)(int) = nullptr;
HWND g_hwnd = nullptr;
HMENU g_menu = nullptr;
HMENU g_view = nullptr;
WNDPROC g_original = nullptr;

const UINT SHADER_DEFAULT = 1001;
const UINT SHADER_WOOD = 1002;

void selectMode(UINT id, int mode)
{
    CheckMenuRadioItem(g_view, SHADER_DEFAULT, SHADER_WOOD, id, MF_BYCOMMAND);
    if (g_onSelect) g_onSelect(mode);
}

LRESULT CALLBACK menuWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_COMMAND)
    {
        switch (LOWORD(wParam))
        {
        case SHADER_DEFAULT: selectMode(SHADER_DEFAULT, 0); return 0;
        case SHADER_WOOD:    selectMode(SHADER_WOOD, 1);    return 0;
        default: break;
        }
    }
    return CallWindowProc(g_original, hwnd, msg, wParam, lParam);
}
}

extern "C" void dcad_install_native_shader_menu(void* window, void* display,
                                                 void (*onSelect)(int))
{
    (void)display;
    g_onSelect = onSelect;
    g_hwnd = static_cast<HWND>(window);
    if (!g_hwnd) return;

    g_view = CreateMenu();
    AppendMenuA(g_view, MF_STRING, SHADER_DEFAULT, "Default (VS Code yellow)");
    AppendMenuA(g_view, MF_STRING, SHADER_WOOD, "Wood (joints GLB)");

    g_menu = CreateMenu();
    AppendMenuA(g_menu, MF_POPUP, reinterpret_cast<UINT_PTR>(g_view), "View");

    SetMenu(g_hwnd, g_menu);
    DrawMenuBar(g_hwnd);
    selectMode(SHADER_DEFAULT, 0);

    g_original = reinterpret_cast<WNDPROC>(
        SetWindowLongPtr(g_hwnd, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(menuWndProc)));
}

extern "C" void dcad_native_menu_poll()
{
    // Win32 dispatches WM_COMMAND through the standard message loop, which
    // GLFW pumps in glfwPollEvents().
}
