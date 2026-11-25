/*
 * Native macOS menu bar for dcad-gui.
 *
 * GLFW does not expose a menu API, so the menus are AppKit NSMenus installed
 * on NSApplication. Items call back into D through plain C function pointers;
 * no ImGui-drawn menu is involved.
 */
#import <AppKit/AppKit.h>

extern "C" void dcad_install_native_menu(void* window, void* display,
                                         void (*onSelect)(int),
                                         void (*onNewProject)());
extern "C" void dcad_native_menu_poll();

namespace {
void (*g_onSelect)(int) = nullptr;
void (*g_onNewProject)() = nullptr;
int g_mode = 0;
NSMenuItem* g_defaultItem = nil;
NSMenuItem* g_woodItem = nil;
id g_target = nil; // menu items do not retain their target

void selectMode(int mode)
{
    g_mode = mode;
    [g_defaultItem setState:(mode == 0 ? NSControlStateValueOn
                                       : NSControlStateValueOff)];
    [g_woodItem setState:(mode == 1 ? NSControlStateValueOn
                                    : NSControlStateValueOff)];
    if (g_onSelect) g_onSelect(mode);
}
}

@interface DcadMenuTarget : NSObject
- (void)selectDefault:(id)sender;
- (void)selectWood:(id)sender;
- (void)newProject:(id)sender;
@end

@implementation DcadMenuTarget
- (void)selectDefault:(id)sender { (void)sender; selectMode(0); }
- (void)selectWood:(id)sender    { (void)sender; selectMode(1); }
- (void)newProject:(id)sender
{
    (void)sender;
    if (g_onNewProject) g_onNewProject();
}
@end

extern "C" void dcad_install_native_menu(void* window, void* display,
                                         void (*onSelect)(int),
                                         void (*onNewProject)())
{
    (void)window;   // AppKit owns the menu bar, not the GLFW window
    (void)display;
    g_onSelect = onSelect;
    g_onNewProject = onNewProject;
    NSApplication* app = [NSApplication sharedApplication];

    NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"dcad"];

    // Keep the standard application menu (About / Hide / Quit) intact.
    NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:@""
                                                     action:nil
                                              keyEquivalent:@""];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"dcad"];
    [appMenu addItemWithTitle:@"About dcad"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide dcad"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem* quit = [appMenu addItemWithTitle:@"Quit dcad"
                                         action:@selector(terminate:)
                                  keyEquivalent:@"q"];
    [quit setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    g_target = [[DcadMenuTarget alloc] init];

    NSMenuItem* fileItem = [[NSMenuItem alloc] initWithTitle:@"File"
                                                      action:nil
                                               keyEquivalent:@""];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem* newItem = [fileMenu addItemWithTitle:@"New Project..."
                                             action:@selector(newProject:)
                                      keyEquivalent:@"n"];
    [newItem setTarget:g_target];
    [newItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    [fileItem setSubmenu:fileMenu];
    [mainMenu addItem:fileItem];

    NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"View"
                                                      action:nil
                                               keyEquivalent:@""];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem* shaderItem = [[NSMenuItem alloc] initWithTitle:@"Shader"
                                                        action:nil
                                                 keyEquivalent:@""];
    NSMenu* shaderMenu = [[NSMenu alloc] initWithTitle:@"Shader"];

    g_defaultItem = [shaderMenu addItemWithTitle:@"Default (VS Code yellow)"
                                          action:@selector(selectDefault:)
                                   keyEquivalent:@""];
    [g_defaultItem setTarget:g_target];
    g_woodItem = [shaderMenu addItemWithTitle:@"Wood (joints GLB)"
                                       action:@selector(selectWood:)
                                keyEquivalent:@""];
    [g_woodItem setTarget:g_target];
    [shaderItem setSubmenu:shaderMenu];
    [viewMenu addItem:shaderItem];
    [viewItem setSubmenu:viewMenu];
    [mainMenu addItem:viewItem];

    [app setMainMenu:mainMenu];
    selectMode(0);
}

extern "C" void dcad_native_menu_poll()
{
    // AppKit dispatches menu events through its own run loop, which GLFW
    // already drives on macOS.
}
