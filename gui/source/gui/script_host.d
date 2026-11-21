/**
 * Script execution via hot-loaded D shared libraries.
 *
 * The editor text is D source. On Run it is wrapped in a tiny generated D
 * module, compiled with ldc2 into a .dylib, and loaded with dlopen. The
 * exported entry point returns a raw TopoDS_Shape*; the host wraps it in its
 * own Shape and meshes it. The previous plugin is unloaded first.
 *
 * TRADEOFF: this is approach (a) from the architecture discussion -- the
 * script really is D, so it has the full language and kernel API available.
 * Cost: a ~1-2 s compile on every Run (fine for manual Ctrl+Enter, too slow
 * for per-keystroke auto-run), and ldc2 must be on PATH. The alternative --
 * an embedded interpreter -- would be faster to re-run but would need a
 * custom parser and a restricted subset of the DSL.
 */
module gui.script_host;

import std.stdio : File;
import std.file : write, remove, exists;
import std.path : buildPath;
import std.process : execute;
import std.string : replace, toStringz, fromStringz;
import std.conv : to;
import core.sys.posix.dlfcn;

import dcad.shape : Shape;
import dcad.occt.topology : TopoDS_Shape, dcad_shape_free;

private enum string prelude = q"PRELUDE_END
import dcad.shape : Shape;
import dcad.dsl.workplane : Workplane;
import dcad.dsl.selector : FaceSelector, EdgeSelector;
import dcad.occt.types : TopAbs_ShapeEnum;
import dcad.occt.topology : dcad_shape_clone;
import std.math : abs, sqrt, PI, sin, cos, floor, ceil;
import std.array;
import std.algorithm;
import std.range;
import std.conv : to;
import std.string : format;

private char[16384] g_errorBuf;
private void setError(string msg) {
    g_errorBuf[] = 0;
    auto s = msg ~ "\0";
    auto n = s.length < g_errorBuf.length ? s.length : g_errorBuf.length;
    g_errorBuf[0 .. n] = s[0 .. n];
}

private Shape toShape(T)(T value) {
    static if (is(T == Shape))
        return value;
    else static if (is(typeof(value.shape) == Shape))
        return value.shape;
    else
        static assert(0, "result must be a Shape or a Workplane");
}

extern(C) export void* dcad_script_run()
{
    try
    {
PRELUDE_END";

private enum string epilogue = q"EPILOGUE_END
        Shape finalShape = toShape(result);
        return cast(void*) dcad_shape_clone(&finalShape.native());
    }
    catch (Throwable t)
    {
        setError(t.toString());
        return null;
    }
}

extern(C) export const(char)* dcad_script_error()
{
    return g_errorBuf.ptr;
}
EPILOGUE_END";

/// Result of a script run: either a shape or an error message.
struct RunResult
{
    Shape shape;
    string error;
    bool ok() const { return error.length == 0 && shape !is null; }
}

final class ScriptHost
{
private:
    string workDir;
    string repoRoot;
    string[] linkArgs;
    string[] importPaths;
    string[] extraSources;
    void* handle;
    int generation;

public:
    this(string workDir, string repoRoot)
    {
        this.workDir = workDir;
        this.repoRoot = repoRoot;
        // Extra source roots scripts may import: bundled samples. LDC does
        // not compile imported modules unless they are passed explicitly, so
        // list the sample's modules as additional translation units.
        immutable sampleDir = buildPath(repoRoot, "samples/coffee-table");
        importPaths = [sampleDir];
        extraSources = [
            buildPath(sampleDir, "coffee_dimensions.d"),
            buildPath(sampleDir, "coffee_util.d"),
            buildPath(sampleDir, "coffee_parts.d"),
        ];
        buildLinkArgs();
    }

    ~this()
    {
        unload();
    }

    /// Compile and run the given script source. Returns a cloned shape that
    /// stays valid after the plugin is unloaded on the next run.
    RunResult run(string source)
    {
        unload();

        immutable stem = "script_" ~ generation.to!string;
        generation++;
        immutable srcPath = buildPath(workDir, stem ~ ".d");
        immutable dylibPath = buildPath(workDir, stem ~ ".dylib");

        write(srcPath, prelude ~ "\n" ~ source ~ "\n" ~ epilogue ~ "\n");
        scope(exit) { if (exists(srcPath)) remove(srcPath); }

        string[] cmd = ["ldc2", "-shared", "-relocation-model=pic",
                        "-I", buildPath(repoRoot, "source")];
        foreach (p; importPaths)
            cmd ~= ["-I", p];
        cmd ~= linkArgs;
        cmd ~= extraSources;
        cmd ~= [srcPath, "-of=" ~ dylibPath];

        auto compiled = execute(cmd);
        if (compiled.status != 0)
        {
            string msg = compiled.output.length ? compiled.output : "ldc2 failed";
            return RunResult(null, msg);
        }

        handle = dlopen(dylibPath.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (handle is null)
            return RunResult(null, "dlopen failed for " ~ dylibPath ~ "\n"
                                   ~ cast(string) fromStringz(dlerror()));

        alias RunFn = extern(C) void* function();
        alias ErrFn = extern(C) const(char)* function();
        auto runFn = cast(RunFn) dlsym(handle, "dcad_script_run");
        auto errFn = cast(ErrFn) dlsym(handle, "dcad_script_error");
        if (runFn is null || errFn is null)
        {
            unload();
            return RunResult(null, "plugin missing dcad_script_run/ dcad_script_error");
        }

        auto p = runFn();
        if (p is null)
        {
            import std.string : fromStringz;
            auto err = fromStringz(errFn()).idup;
            unload();
            return RunResult(null, err.length ? err : "script returned no shape");
        }

        auto shape = new Shape(*cast(TopoDS_Shape*) p);
        dcad_shape_free(p);
        return RunResult(shape, null);
    }

private:
    void unload()
    {
        if (handle !is null)
        {
            dlclose(handle);
            handle = null;
        }
    }

    void buildLinkArgs()
    {
        // OCCT libraries, mirroring dub.sdl so the plugin can instantiate
        // shapes through the same static shim the host uses.
        enum string[] occtLibs = [
            "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKGeomAlgo",
            "TKBRep", "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKFillet",
            "TKOffset", "TKXSBase", "TKDE", "TKDESTEP", "TKMesh"
        ];
        linkArgs ~= "-L-L" ~ buildPath(repoRoot, "build");
        linkArgs ~= "-L-ldcad_shim";
        linkArgs ~= "-L-L/opt/homebrew/lib";
        linkArgs ~= "-L-rpath";
        linkArgs ~= "-L/opt/homebrew/lib";
        foreach (lib; occtLibs)
            linkArgs ~= "-L-l" ~ lib;
        linkArgs ~= "-L-lc++";
        linkArgs ~= buildPath(repoRoot, "libdcad.a");
    }
}

import std.string : fromStringz;
