/**
 * Platform shims for the GUI host.
 *
 * GLFW hides most window-system differences, but three things do not port by
 * themselves: dynamic loading of hot-loaded scripts, the process id used for
 * temporary directories, and the linker arguments needed to build those
 * scripts. Everything OS-specific lives here so app.d and script_host.d stay
 * platform-neutral.
 */
module gui.platform;

import std.path : buildPath, dirName;
import std.file : exists, thisExePath, getcwd;
import std.string : toStringz, fromStringz;
import std.conv : to;

version (Windows)
{
    import core.sys.windows.windows;
}
else version (Posix)
{
    import core.sys.posix.unistd : getpid;
    import core.sys.posix.dlfcn;
}

/// Extension used by the native dynamic loader.
string sharedLibraryExtension()
{
    version (Windows) return ".dll";
    else version (OSX) return ".dylib";
    else return ".so";
}

/// Process id, used only to keep each session's scratch directory unique.
int processId()
{
    version (Windows) return cast(int) GetCurrentProcessId();
    else return cast(int) getpid();
}

private bool hasGuiAssets(string dir)
{
    return exists(buildPath(dir, "samples", "coffee-table", "table.d")) &&
           (exists(buildPath(dir, "assets")) ||
            exists(buildPath(dir, "gui", "assets")));
}

/**
 * Root for all runtime resources (scripts, icons, fonts, script SDK).
 *
 * A self-extracting launcher places the real GUI in a cache directory together
 * with its assets and libraries, so the GUI never depends on the caller's
 * working directory. In a source checkout the repository root is detected as
 * the fallback, so `dub run :gui` keeps working.
 */
string resourceRoot()
{
    auto exeDir = dirName(thisExePath());
    if (hasGuiAssets(exeDir)) return exeDir;
    auto cwd = getcwd();
    if (hasGuiAssets(cwd)) return cwd;
    return exeDir;
}

/**
 * dlopen(3) on POSIX, LoadLibraryA on Windows. Deliberately tiny: the script
 * host only needs open/symbol/close, and keeping the handle in a value type
 * avoids any GC state crossing a plugin unload.
 */
struct DynamicLibrary
{
private:
    void* handle;

public:
    static DynamicLibrary open(string path, ref string error)
    {
        DynamicLibrary result;
        version (Windows)
        {
            result.handle = cast(void*) LoadLibraryA(path.toStringz);
            if (result.handle is null)
                error = "LoadLibrary failed for " ~ path ~ " (error "
                      ~ GetLastError().to!string ~ ")";
        }
        else
        {
            result.handle = dlopen(path.toStringz, RTLD_NOW | RTLD_LOCAL);
            if (result.handle is null)
            {
                auto detail = dlerror();
                error = "dlopen failed for " ~ path
                      ~ (detail is null ? "" : "\n" ~ fromStringz(detail).idup);
            }
        }
        return result;
    }

    bool loaded() const { return handle !is null; }

    /// `name` must be a literal (or otherwise NUL-terminated): the destructor
    /// may call this during GC finalisation, where allocating is forbidden.
    void* symbol(const(char)* name) nothrow @nogc
    {
        if (handle is null) return null;
        version (Windows)
            return cast(void*) GetProcAddress(cast(HMODULE) handle, name);
        else
            return dlsym(handle, name);
    }

    void close()
    {
        if (handle is null) return;
        version (Windows) FreeLibrary(cast(HMODULE) handle);
        else dlclose(handle);
        handle = null;
    }
}

/// OCCT libraries required by both the host and the generated plugins.
private enum string[] commonOcctLibraries = [
    "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKGeomAlgo",
    "TKBRep", "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKFillet",
    "TKOffset", "TKXSBase", "TKMesh"
];
/// Homebrew and the official MSVC package ship aggregate Data Exchange libs.
private enum string[] bundledOcctExtras = ["TKDE", "TKDESTEP"];
/// Debian/Ubuntu OCCT 7.7 splits the same functionality into step libraries.
private enum string[] distroOcctExtras = [
    "TKSTEP", "TKSTEPBase", "TKSTEPAttr", "TKSTEP209", "TKXDESTEP",
    "TKXDEIGES"
];

/**
 * Linker arguments for `ldc2 -shared` when compiling a script plugin.
 * Each entry is passed verbatim after ldc2's own `-L` prefix convention,
 * matching the flags dub uses for the host executable.
 */
string[] pluginLinkArgs(string repoRoot)
{
    string[] args;
    version (Windows)
    {
        // CI (and the README recipe) stage prebuilt artifacts here. Release
        // archives carry the same import libraries in lib/, so prefer those.
        args ~= "-L/LIBPATH:" ~ buildPath(repoRoot, "build");
        auto bundledLib = buildPath(repoRoot, "lib");
        if (exists(buildPath(bundledLib, "TKernel.lib")))
            args ~= "-L/LIBPATH:" ~ bundledLib;
        else
            args ~= "-L/LIBPATH:C:\\dcad\\occt\\lib";
        args ~= "-Ldcad_shim.lib";
        foreach (lib; commonOcctLibraries ~ bundledOcctExtras)
            args ~= "-L" ~ lib ~ ".lib";
        auto core = buildPath(repoRoot, "dcad.lib");
        if (!exists(core)) core = buildPath(repoRoot, "libdcad.a");
        args ~= core;
    }
    else version (OSX)
    {
        args ~= "-L-L" ~ buildPath(repoRoot, "build");
        args ~= "-L-ldcad_shim";
        auto bundledLib = buildPath(repoRoot, "lib");
        if (exists(buildPath(bundledLib, "libTKernel.dylib")))
        {
            args ~= "-L-L" ~ bundledLib;
            args ~= "-L-rpath";
            args ~= "-L" ~ bundledLib;
        }
        else
        {
            args ~= "-L-L/opt/homebrew/lib";
            args ~= "-L-rpath";
            args ~= "-L/opt/homebrew/lib";
            args ~= "-L-L/usr/local/lib";
        }
        foreach (lib; commonOcctLibraries ~ bundledOcctExtras)
            args ~= "-L-l" ~ lib;
        args ~= "-L-lc++";
        args ~= buildPath(repoRoot, "libdcad.a");
    }
    else
    {
        args ~= "-L-L" ~ buildPath(repoRoot, "build");
        args ~= "-L-ldcad_shim";
        auto bundledLib = buildPath(repoRoot, "lib");
        if (exists(buildPath(bundledLib, "libTKernel.so")))
            args ~= "-L-L" ~ bundledLib;
        foreach (lib; commonOcctLibraries ~ distroOcctExtras)
            args ~= "-L-l" ~ lib;
        args ~= "-L-lstdc++";
        args ~= buildPath(repoRoot, "libdcad.a");
    }
    return args;
}

/// Native GLFW handle used by the platform menu implementation.
extern(C) nothrow @nogc
{
    void* glfwGetWin32Window(void* window);
    void* glfwGetX11Window(void* window);
    void* glfwGetX11Display();
}

struct NativeWindowHandles
{
    void* window;
    void* display;
}

/// GLFW's native window/display pair, for attaching a platform menu bar.
NativeWindowHandles nativeHandles(void* glfwWindow)
{
    version (Windows)
        return NativeWindowHandles(glfwGetWin32Window(glfwWindow), null);
    else version (linux)
        return NativeWindowHandles(glfwGetX11Window(glfwWindow),
                                   glfwGetX11Display());
    else
        return NativeWindowHandles(null, null);
}
