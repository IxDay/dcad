/**
 * Self-extracting launcher for the released dcad-gui.
 *
 * This executable links only libc/druntime/Phobos. Its own binary contains a
 * ZIP with the real GUI, its assets, D sources, import libraries and native
 * libraries. On first launch those are expanded into a versioned cache under
 * the user's data directory; the real GUI is then started from there, so it
 * never needs OCCT, GLFW or an asset directory installed on the host.
 */
module launcher.main;

import std.file : exists, copy, dirEntries, SpanMode;
import std.path : baseName, buildPath;
import std.stdio : stderr, writeln;
import std.string : toStringz;

version (Posix)
    import std.process : execv;
version (Windows)
    import std.process : spawnProcess, wait;

import launcher.embedded : prepareResources;

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

int main(string[] args)
{
    auto state = prepareResources();
    if (!state.embedded || !exists(state.root))
    {
        stderr.writeln("dcad: this build has no embedded runtime payload; "
                       ~ "run the GUI from a source checkout instead");
        return 1;
    }

    // Optional diagnostic used by the release smoke tests.
    if (args.length > 1 && args[1] == "--print-root")
    {
        writeln(state.root);
        return 0;
    }

    version (Windows)
        enum innerName = "dcad-gui.exe";
    else
        enum innerName = "dcad-gui";
    immutable inner = buildPath(state.root, innerName);
    if (!exists(inner))
    {
        stderr.writeln("dcad: embedded GUI binary is missing from ", state.root);
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
        // libraries in lib/ for the hot compiler, but stage every DLL flat.
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
            stderr.writeln("dcad: failed to start ", inner, ": ", e.msg);
            return 1;
        }
    }
    else
    {
        // execv replaces this process, so exit codes and signals are those of
        // the GUI itself and no launcher process stays behind.
        execv(inner, args);
        stderr.writeln("dcad: failed to start ", inner);
        return 1;
    }
}
