/*
 * Native-looking menu bar for dcad-gui on X11.
 *
 * GLFW has no menu API and X11 itself has no menu widget, so this draws a
 * small override-redirect menu bar and popup using Xlib directly. The bar is a
 * child of the GLFW window; the popup is a child of the root window so it can
 * be raised above the GLFW surface. Events for these two windows are drained
 * in dcad_native_menu_poll() before GLFW polls, which keeps the two event
 * loops from stealing each other's messages.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#include <cstdint>
#include <cstring>

extern "C" void dcad_install_native_shader_menu(void* window, void* display,
                                                 void (*onSelect)(int));
extern "C" void dcad_native_menu_poll();

namespace
{
const int BAR_HEIGHT = 24;
const int POPUP_WIDTH = 224;
const int POPUP_HEIGHT = 48;

void (*g_onSelect)(int) = nullptr;
Display* g_display = nullptr;
Window g_parent = None;
Window g_bar = None;
Window g_popup = None;
GC g_gc = nullptr;
XFontStruct* g_font = nullptr;
bool g_popupOpen = false;
int g_mode = 0;
unsigned int g_barWidth = 0;

void drawBar()
{
    XClearWindow(g_display, g_bar);
    XDrawString(g_display, g_bar, g_gc, 10, 16, "View", 4);
    const char* label = g_mode == 0 ? "Shader: Default" : "Shader: Wood";
    XDrawString(g_display, g_bar, g_gc, 64, 16, label,
                static_cast<int>(std::strlen(label)));
}

void drawPopup()
{
    XClearWindow(g_display, g_popup);
    XDrawRectangle(g_display, g_popup, g_gc, 2, 2, POPUP_WIDTH - 5,
                   POPUP_HEIGHT - 5);
    XDrawLine(g_display, g_popup, g_gc, 2, BAR_HEIGHT, POPUP_WIDTH - 3,
              BAR_HEIGHT);
    XDrawString(g_display, g_popup, g_gc, 10, 16,
                "Default (VS Code yellow)", 24);
    XDrawString(g_display, g_popup, g_gc, 10, 40, "Wood (joints GLB)", 17);
    int y = g_mode == 0 ? 10 : 34;
    XFillRectangle(g_display, g_popup, g_gc, POPUP_WIDTH - 16, y, 8, 8);
}

void closePopup()
{
    if (!g_popupOpen) return;
    XUnmapWindow(g_display, g_popup);
    XUngrabPointer(g_display, CurrentTime);
    XFlush(g_display);
    g_popupOpen = false;
}

void openPopup()
{
    Window root;
    int parentX, parentY;
    Window child;
    unsigned int width, height, border, depth;
    if (!XGetGeometry(g_display, g_parent, &root, &parentX, &parentY, &width,
                      &height, &border, &depth))
        return;
    int absX = 0, absY = 0;
    XTranslateCoordinates(g_display, g_parent, root, 0, BAR_HEIGHT,
                          &absX, &absY, &child);
    XMoveWindow(g_display, g_popup, absX, absY);
    XMapRaised(g_display, g_popup);
    XGrabPointer(g_display, g_popup, True,
                 ButtonPressMask | ButtonReleaseMask,
                 GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
    XFlush(g_display);
    g_popupOpen = true;
}
}

extern "C" void dcad_install_native_shader_menu(void* window, void* display,
                                                 void (*onSelect)(int))
{
    g_onSelect = onSelect;
    g_display = static_cast<Display*>(display);
    g_parent = static_cast<Window>(reinterpret_cast<uintptr_t>(window));
    if (!g_display || g_parent == None) return;

    Window root;
    int x, y;
    unsigned int width, height, border, depth;
    XGetGeometry(g_display, g_parent, &root, &x, &y, &width, &height,
                 &border, &depth);
    g_barWidth = width;

    g_bar = XCreateSimpleWindow(g_display, g_parent, 0, 0, width, BAR_HEIGHT,
                                0, WhitePixel(g_display, 0),
                                WhitePixel(g_display, 0));
    XSelectInput(g_display, g_bar,
                 ExposureMask | ButtonPressMask | ButtonReleaseMask);
    XMapWindow(g_display, g_bar);

    g_popup = XCreateSimpleWindow(g_display, root, 0, 0, POPUP_WIDTH,
                                  POPUP_HEIGHT, 1, BlackPixel(g_display, 0),
                                  WhitePixel(g_display, 0));
    XSetWindowAttributes attrs;
    attrs.override_redirect = True;
    XChangeWindowAttributes(g_display, g_popup, CWOverrideRedirect, &attrs);
    XSelectInput(g_display, g_popup,
                 ExposureMask | ButtonPressMask | ButtonReleaseMask);

    g_gc = XCreateGC(g_display, g_bar, 0, nullptr);
    g_font = XLoadQueryFont(g_display, "fixed");
    if (g_font) XSetFont(g_display, g_gc, g_font->fid);
    XSetForeground(g_display, g_gc, BlackPixel(g_display, 0));
    XFlush(g_display);
}

extern "C" void dcad_native_menu_poll()
{
    if (!g_display || g_bar == None) return;

    Window root;
    int x, y;
    unsigned int width, height, border, depth;
    if (XGetGeometry(g_display, g_parent, &root, &x, &y, &width, &height,
                     &border, &depth) && width != g_barWidth)
    {
        g_barWidth = width;
        XResizeWindow(g_display, g_bar, width, BAR_HEIGHT);
    }

    XEvent ev;
    while (XCheckWindowEvent(g_display, g_bar,
                             ExposureMask | ButtonPressMask, &ev))
    {
        if (ev.type == Expose)
        {
            if (ev.xexpose.count == 0) drawBar();
        }
        else if (ev.type == ButtonPress && !g_popupOpen)
        {
            openPopup();
        }
    }

    if (!g_popupOpen) return;
    while (XCheckWindowEvent(g_display, g_popup,
                             ExposureMask | ButtonPressMask |
                             ButtonReleaseMask, &ev))
    {
        if (ev.type == Expose)
        {
            if (ev.xexpose.count == 0) drawPopup();
        }
        else if (ev.type == ButtonPress)
        {
            const int px = ev.xbutton.x;
            const int py = ev.xbutton.y;
            if (px < 0 || px > POPUP_WIDTH || py < 0 || py > POPUP_HEIGHT)
            {
                closePopup();
            }
            else
            {
                g_mode = py < BAR_HEIGHT ? 0 : 1;
                closePopup();
                if (g_onSelect) g_onSelect(g_mode);
                drawBar();
            }
            break;
        }
    }
}
