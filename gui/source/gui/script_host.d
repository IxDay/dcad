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
import dcad.occt.topology : dcad_shape_clone, dcad_shape_free;
import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;
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

private string partLabel(T)(ref T part) {
    static if (is(typeof(part.name) == string))
        return part.name;
    else static if (is(typeof(part.id) == string))
        return part.id;
    else
        return "part";
}

/* Optional animation protocol. A script opts in by defining, inside its own
 * source (which is injected into dcad_script_run), these two locals:
 *   auto animParts = <array of NamedPart-like values with .id and .shape>;
 *   auto animPoses = <array of double[3][string] keyframes>; // t in [0,1]
 *
 * The data is copied into malloc'd buffers, NOT GC-managed plugin globals:
 * the plugin's static data is not necessarily a GC root for the host's
 * collector, so AA/array globals get collected between frames. C++ shape
 * clones are used for the same reason. Scripts that do not opt in pay
 * nothing. */
private void** g_animShapePtrs;
private char** g_animNames;
private size_t g_animShapeCount;
private double* g_poseData;
private size_t g_poseFrames;
private size_t g_poseParts;

extern(C) export void* dcad_script_run()
{
    try
    {
PRELUDE_END";

private enum string epilogue = q"EPILOGUE_END
        // Capture optional animation hooks while the script's locals are in
        // scope (the generated source is inserted inside this function).
        static if (is(typeof(animParts)) && is(typeof(animPoses)))
        {
            immutable np = animParts.length;
            immutable nf = animPoses.length;
            g_animShapeCount = np;
            g_poseFrames = nf;
            g_poseParts = np;
            if (np > 0)
            {
                g_animShapePtrs = cast(void**) malloc(np * size_t.sizeof);
                g_animNames = cast(char**) malloc(np * size_t.sizeof);
            }
            if (nf > 0 && np > 0)
            {
                g_poseData = cast(double*) malloc(nf * np * 3 * double.sizeof);
                if (g_poseData !is null)
                    foreach (k; 0 .. nf * np * 3)
                        g_poseData[k] = 0.0;
            }
            foreach (i, p; animParts)
            {
                auto s = toShape(p.shape);
                if (g_animShapePtrs !is null)
                    g_animShapePtrs[i] = dcad_shape_clone(&s.native());
                if (g_animNames !is null)
                {
                    auto label = partLabel(p);
                    auto name = cast(char*) malloc(label.length + 1);
                    if (name !is null)
                    {
                        memcpy(name, label.ptr, label.length);
                        name[label.length] = 0;
                    }
                    g_animNames[i] = name;
                }
                if (g_poseData !is null)
                    foreach (fi, pose; animPoses)
                        if (auto v = p.id in pose)
                            foreach (k; 0 .. 3)
                                g_poseData[(fi * np + i) * 3 + k] = (*v)[k];
            }
        }

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

extern(C) export int dcad_anim_part_count()
{
    return cast(int) g_animShapeCount;
}

extern(C) export const(void)* dcad_anim_part_shape(int i)
{
    if (i < 0 || i >= g_animShapeCount || g_animShapePtrs is null) return null;
    return g_animShapePtrs[i];
}

extern(C) export const(char)* dcad_anim_part_name(int i)
{
    if (i < 0 || i >= g_animShapeCount || g_animNames is null) return null;
    return g_animNames[i];
}

/// Linear interpolation between keyframes, written as dx/dy/dz per part.
extern(C) export void dcad_anim_pose(double t, double* offsets)
{
    if (g_poseData is null || g_poseFrames == 0 || g_poseParts == 0) return;
    immutable last = g_poseFrames - 1;
    immutable x = (t < 0 ? 0 : t > 1 ? 1 : t) * cast(double) last;
    immutable i0 = cast(size_t) x;
    immutable i1 = i0 < last ? i0 + 1 : last;
    immutable f = x - cast(double) i0;
    foreach (p; 0 .. g_poseParts)
        foreach (k; 0 .. 3)
        {
            immutable a = g_poseData[(i0 * g_poseParts + p) * 3 + k];
            immutable b = g_poseData[(i1 * g_poseParts + p) * 3 + k];
            offsets[p * 3 + k] = a + (b - a) * f;
        }
}

/// Release C-owned buffers before dlclose().
extern(C) export void dcad_anim_free()
{
    if (g_animShapePtrs !is null)
    {
        foreach (i; 0 .. g_animShapeCount)
            if (g_animShapePtrs[i] !is null)
                dcad_shape_free(g_animShapePtrs[i]);
        free(g_animShapePtrs);
    }
    if (g_animNames !is null)
    {
        foreach (i; 0 .. g_animShapeCount)
            if (g_animNames[i] !is null) free(g_animNames[i]);
        free(g_animNames);
    }
    if (g_poseData !is null) free(g_poseData);
    g_animShapePtrs = null;
    g_animNames = null;
    g_poseData = null;
    g_animShapeCount = 0;
    g_poseFrames = 0;
    g_poseParts = 0;
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
            buildPath(sampleDir, "coffee_motion.d"),
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

    /// True when the loaded script exported at least one animation part.
    bool hasAnimation()
    {
        return animPartCount() > 0;
    }

    int animPartCount()
    {
        if (handle is null) return 0;
        alias Fn = extern(C) int function();
        auto fn = cast(Fn) dlsym(handle, "dcad_anim_part_count");
        return fn is null ? 0 : fn();
    }

    /// Raw pointer to a part shape; valid until the next run() unloads the plugin.
    const(void)* animPartShape(int i)
    {
        if (handle is null) return null;
        alias Fn = extern(C) const(void)* function(int);
        auto fn = cast(Fn) dlsym(handle, "dcad_anim_part_shape");
        return fn is null ? null : fn(i);
    }

    /// Display name for an animation part; valid until the next run().
    string animPartName(int i)
    {
        if (handle is null) return null;
        alias Fn = extern(C) const(char)* function(int);
        auto fn = cast(Fn) dlsym(handle, "dcad_anim_part_name");
        if (fn is null) return null;
        auto p = fn(i);
        return p is null ? null : fromStringz(p).idup;
    }

    /// 3 doubles (dx,dy,dz) per part at normalised time t.
    double[] animPose(double t, int count)
    {
        if (handle is null || count <= 0) return null;
        alias Fn = extern(C) void function(double, double*);
        auto fn = cast(Fn) dlsym(handle, "dcad_anim_pose");
        if (fn is null) return null;
        auto offsets = new double[count * 3];
        fn(t, offsets.ptr);
        return offsets;
    }

private:
    void unload()
    {
        if (handle !is null)
        {
            // Free C-owned animation buffers while the plugin is still loaded.
            alias FreeFn = extern(C) void function();
            auto freeFn = cast(FreeFn) dlsym(handle, "dcad_anim_free");
            if (freeFn !is null) freeFn();
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
