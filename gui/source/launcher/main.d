/**
 * Self-extracting launcher for the released dcad-gui.
 *
 * This executable links only libc/druntime/Phobos. Its own binary contains a
 * ZIP with the real GUI, its assets, D sources, import libraries and native
 * libraries. On first launch those are expanded into a versioned cache under
 * the user's data directory; the real GUI is then started from there, so it
 * never needs OCCT, GLFW or an asset directory installed on the host.
 *
 * The Windows build uses the GUI subsystem and a WinMain entry point, so
 * double-clicking it never allocates a console window. The POSIX build uses a
 * normal main because .app bundles and desktop launchers already suppress a
 * terminal.
 */
module launcher.main;

import std.file : exists, copy, dirEntries, SpanMode, write;
import std.path : baseName, buildPath;
import std.stdio : stderr, writeln;
import std.string : toStringz;

version (Posix)
    import std.process : execv;
version (Windows)
{
    import core.sys.windows.shellapi : CommandLineToArgvW;
    import core.sys.windows.winbase : GetCommandLineW, LocalFree;
    import std.process : spawnProcess, wait;
}

import launcher.embedded : prepareResources;

/// Fatal errors cannot go to a console in a GUI-subsystem Windows build, so
/// show them in a native message box there and on stderr on POSIX.
private void reportError(string text)
{
    version (Windows)
    {
        import core.sys.windows.winuser : MessageBoxA, MB_OK, MB_ICONERROR;

        MessageBoxA(null, ("dcad: " ~ text).toStringz, "dcad".toStringz,
                    MB_OK | MB_ICONERROR);
    }
    else
        stderr.writeln("dcad: ", text);
}

/// `--print-root` is used by the acceptance suite. A GUI-subsystem binary has
/// no stdout, so an environment variable can redirect the answer to a file.
private void printRoot(string root, string[] args)
{
    if (args.length < 2 || args[1] != "--print-root") return;

    import std.process : environment;

    immutable diagnostic = environment.get("DCAD_PRINT_ROOT_FILE", "");
    if (diagnostic.length)
        write(diagnostic, root);
    else
        writeln(root);
}

private int launch(string[] args)
{
    auto state = prepareResources();
    if (!state.embedded || !exists(state.root))
    {
        reportError("this build has no embedded runtime payload; "
                    ~ "run the GUI from a source checkout instead");
        return 1;
    }

    printRoot(state.root, args);
    if (args.length > 1 && args[1] == "--print-root")
        return 0;

    version (Windows)
        enum innerName = "dcad-gui.exe";
    else
        enum innerName = "dcad-gui";
    immutable inner = buildPath(state.root, innerName);
    if (!exists(inner))
    {
        reportError("embedded GUI binary is missing from " ~ state.root);
        return 1;
    }

    version (Posix)
    {
        import core.sys.posix.sys.stat : chmod;

        // ZIP members are written as plain data; restore the executable bit.
        import std.conv : octal;

        chmod(inner.toStringz, octal!755);
    }

    version (Windows)
    {
        // Windows searches for DLLs next to the executable. Keep import
        // libraries in lib/ for the hot compiler, but stage every DLL flat
        // beside the inner GUI. The payload stores them under lib/ directly.
        auto libDir = buildPath(state.root, "lib");
        if (exists(libDir))
            foreach (entry; dirEntries(libDir, "*.dll", SpanMode.shallow))
            {
                immutable target = buildPath(state.root, baseName(entry.name));
                if (!exists(target)) copy(entry.name, target);
            }
    }
    else
    {
        import core.sys.posix.stdlib : setenv;

        // Linux needs the loader path before exec; macOS honours
        // DYLD_LIBRARY_PATH for @rpath dylibs as well, and the GUI binary
        // also carries @executable_path/lib as a fallback.
        auto libDir = buildPath(state.root, "lib");
        version (OSX)
            setenv("DYLD_LIBRARY_PATH".toStringz,
                   prependPath("DYLD_LIBRARY_PATH", libDir).toStringz, 1);
        else
            setenv("LD_LIBRARY_PATH".toStringz,
                   prependPath("LD_LIBRARY_PATH", libDir).toStringz, 1);
    }

    version (Windows)
    {
        // The MSVC runtime has no execv, so wait for the GUI and return its
        // exit code. The launcher stays alive only as its waiting parent.
        string[] childArgs = [inner] ~ args[1 .. $];
        try
            return wait(spawnProcess(childArgs));
        catch (Exception e)
        {
            reportError("failed to start " ~ inner ~ ": " ~ e.msg);
            return 1;
        }
    }
    else
    {
        // execv replaces this process, so exit codes and signals are those of
        // the GUI itself and no launcher process stays behind.
        execv(inner, args);
        reportError("failed to start " ~ inner);
        return 1;
    }
}

private string prependPath(string name, string directory)
{
    import core.stdc.stdlib : getenv;
    import std.string : fromStringz;

    const current = getenv(name.toStringz);
    auto value = current is null ? "" : fromStringz(current).idup;
    version (Windows)
        enum sep = ';';
    else
        enum sep = ':';
    return value.length ? directory ~ sep ~ value : directory;
}

version (Windows)
{
    // CommandLineToArgvW lives in shell32.
    pragma(lib, "shell32.lib");

    // druntime's wide main wrapper sets up `string[]` arguments, initialises the
    // GC and module constructors, catches exceptions and terminates the runtime.
    // A custom WinMain must call it because LDC only emits that wrapper for a
    // regular D `main`.
    alias LauncherMainFunc = extern (C) int function(char[][] args);
    extern (C) int _d_wrun_main(int argc, wchar** wargv,
                                LauncherMainFunc mainFunc);

    extern (C) int dcadLauncherMain(char[][] args)
    {
        return launch(cast(string[]) args);
    }

    /// GUI entry point: no console is created for this process.
    extern (Windows)
    int WinMain(void* hInstance, void* hPrevInstance, char* lpCmdLine, int nCmdShow)
    {
        int argc;
        auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        if (argv is null) return 1;
        scope(exit) LocalFree(argv);
        return _d_wrun_main(argc, argv, &dcadLauncherMain);
    }
}
else
{
    int main(string[] args)
    {
        return launch(args);
    }
}
