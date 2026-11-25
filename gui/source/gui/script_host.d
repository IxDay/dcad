/**
 * Script execution via hot-loaded D shared libraries.
 *
 * The editor text is D source. On Run it is wrapped in a tiny generated D
 * module, compiled with ldc2 into a shared library, and loaded by the native
 * dynamic loader. The
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
import std.file : write, remove, exists, dirEntries, SpanMode;
import std.path : buildPath;
import std.process : execute;
import std.regex : ctRegex, matchFirst, replaceFirst;
import std.algorithm.sorting : sort;
import std.string : replace, toStringz, fromStringz;
import std.conv : to;
import gui.platform : DynamicLibrary, sharedLibraryExtension, pluginLinkArgs;

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

private string partId(T)(ref T part) {
    static if (is(typeof(part.id) == string))
        return part.id;
    else static if (is(typeof(part.name) == string))
        return part.name;
    else
        return "part";
}

/* Optional animation protocol. A body-style script defines two locals; a
 * module-style script exposes two functions with the same values:
 *   <array of NamedPart-like values with .id and .shape>;
 *   <array of double[3][string] keyframes>; // t in [0,1]
 * Functions rather than module variables: D tries to evaluate module-level
 * initialisers at compile time, which cannot work for OCCT calls.
 *
 * The data is copied into malloc'd buffers, NOT GC-managed plugin globals:
 * the plugin's static data is not necessarily a GC root for the host's
 * collector, so AA/array globals get collected between frames. C++ shape
 * clones are used for the same reason. Scripts that do not opt in pay
 * nothing. */
private void** g_animShapePtrs;
private char** g_animNames;
private char** g_animIds;
private size_t g_animShapeCount;
private double* g_poseData;
private size_t g_poseFrames;
private size_t g_poseParts;

private void captureAnimation(Parts, Poses)(Parts parts, Poses poses)
{
    immutable np = parts.length;
    immutable nf = poses.length;
    g_animShapeCount = np;
    g_poseFrames = nf;
    g_poseParts = np;
    if (np > 0)
    {
        g_animShapePtrs = cast(void**) malloc(np * size_t.sizeof);
        g_animNames = cast(char**) malloc(np * size_t.sizeof);
        g_animIds = cast(char**) malloc(np * size_t.sizeof);
    }
    if (nf > 0 && np > 0)
    {
        g_poseData = cast(double*) malloc(nf * np * 3 * double.sizeof);
        if (g_poseData !is null)
            foreach (k; 0 .. nf * np * 3)
                g_poseData[k] = 0.0;
    }
    foreach (i, p; parts)
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
        if (g_animIds !is null)
        {
            auto ident = partId(p);
            auto name = cast(char*) malloc(ident.length + 1);
            if (name !is null)
            {
                memcpy(name, ident.ptr, ident.length);
                name[ident.length] = 0;
            }
            g_animIds[i] = name;
        }
        if (g_poseData !is null)
            foreach (fi, pose; poses)
                if (auto v = p.id in pose)
                    foreach (k; 0 .. 3)
                        g_poseData[(fi * np + i) * 3 + k] = (*v)[k];
    }
}

extern(C) export void* dcad_script_run()
{
    try
    {
PRELUDE_END";

// Body-style scripts inject their source here; the epilogue captures their
// locals while they are still in scope.
private enum string bodyEnd = q"BODY_END
        static if (is(typeof(animParts)) && is(typeof(animPoses)))
            captureAnimation(animParts, animPoses);

        Shape finalShape = toShape(result);
        return cast(void*) dcad_shape_clone(&finalShape.native());
    }
    catch (Throwable t)
    {
        setError(t.toString());
        return null;
    }
}
BODY_END";

// Module-style scripts are compiled as their own translation unit. The entry
// point is dcadMain(); per-element modules only need build() and are displayed
// directly when opened from the project tree. Both forms share the same ABI.
private string moduleBodyEnd(string modName)
{
    return "        import " ~ modName ~ ";\n" ~ q"MOD_BODY_END
        static if (__traits(compiles, dcadParts()) && __traits(compiles, dcadPoses()))
            captureAnimation(dcadParts(), dcadPoses());

        Shape finalShape;
        static if (__traits(compiles, dcadMain()))
            finalShape = toShape(dcadMain());
        else static if (__traits(compiles, build()))
            finalShape = toShape(build());
        else
            static assert(0, "Module script must expose Shape dcadMain() or Shape build()");
        return cast(void*) dcad_shape_clone(&finalShape.native());
    }
    catch (Throwable t)
    {
        setError(t.toString());
        return null;
    }
}
MOD_BODY_END";
}

private enum string tail = q"TAIL_END

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

extern(C) export const(char)* dcad_anim_part_id(int i)
{
    if (i < 0 || i >= g_animShapeCount || g_animIds is null) return null;
    return g_animIds[i];
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
    if (g_animIds !is null)
    {
        foreach (i; 0 .. g_animShapeCount)
            if (g_animIds[i] !is null) free(g_animIds[i]);
        free(g_animIds);
    }
    if (g_poseData !is null) free(g_poseData);
    g_animShapePtrs = null;
    g_animNames = null;
    g_animIds = null;
    g_poseData = null;
    g_animShapeCount = 0;
    g_poseFrames = 0;
    g_poseParts = 0;
}
TAIL_END";

private enum moduleDecl = ctRegex!`(?m)^\s*module\s+[\w.]+\s*;`;

/// A source with a module declaration is a real D module rather than a body.
private bool isModuleSource(string source)
{
    return !matchFirst(source, moduleDecl).empty;
}

/// Give the editor module a private name so it can be compiled alongside the
/// registered element modules without colliding with their declared names.
private string asModule(string source, string modName)
{
    return replaceFirst(source, moduleDecl, "module " ~ modName ~ ";");
}

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
    DynamicLibrary lib;
    int generation;

public:
    this(string workDir, string repoRoot)
    {
        this.workDir = workDir;
        this.repoRoot = repoRoot;
        // LDC does not follow imports, so every module of the bundled sample
        // is passed explicitly. One flat directory keeps this automatic:
        // dimensions, util, one file per part, motion and the table assembly.
        immutable sampleDir = buildPath(repoRoot, "samples/coffee-table");
        importPaths = [sampleDir];
        if (exists(sampleDir))
        {
            foreach (entry; dirEntries(sampleDir, "*.d", SpanMode.shallow))
                extraSources ~= entry.name;
            extraSources.sort();
        }
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
        immutable dylibPath = buildPath(workDir, stem ~ sharedLibraryExtension());
        immutable objPath = buildPath(workDir, stem ~ ".o");

        // Two script forms share one plugin ABI:
        //  * body form (legacy): editor text is the body of dcad_script_run;
        //  * module form: editor text is a real D module exposing dcadMain()
        //    or build(). It gets its own translation unit plus a generated
        //    wrapper, so an element file can be run directly without a
        //    separate viewer script.
        immutable moduleForm = isModuleSource(source);
        string modSrcPath;
        string modName;
        if (moduleForm)
        {
            modName = stem ~ "_mod";
            modSrcPath = buildPath(workDir, modName ~ ".d");
            write(modSrcPath, asModule(source, modName));
        }
        write(srcPath, prelude ~ "\n"
              ~ (moduleForm ? moduleBodyEnd(modName) : source ~ "\n" ~ bodyEnd)
              ~ tail ~ "\n");
        // Nothing generated is kept: the mapping survives unlinking on POSIX,
        // and closing the library only needs the loaded handle, not the path.
        scope(exit)
        {
            if (exists(srcPath)) remove(srcPath);
            if (modSrcPath.length && exists(modSrcPath)) remove(modSrcPath);
            if (exists(objPath)) remove(objPath);
            if (exists(dylibPath)) remove(dylibPath);
        }

        string[] cmd = ["ldc2", "-shared", "-relocation-model=pic"];
        version (Windows)
        {
            // -shared normally implies -link-defaultlib-shared, which expects
            // a DLL copy of druntime/Phobos and leaves D TypeInfo symbols in
            // the core library unresolved. The host and shims use the static
            // MSVC CRT, so build plugins against the static D runtime too.
            cmd ~= "-link-defaultlib-shared=false";
        }
        cmd ~= ["-I", buildPath(repoRoot, "source")];
        foreach (p; importPaths)
            cmd ~= ["-I", p];
        cmd ~= linkArgs;
        cmd ~= extraSources;
        if (modSrcPath.length)
            cmd ~= modSrcPath;
        cmd ~= [srcPath, "-of=" ~ dylibPath];

        auto compiled = execute(cmd);
        if (compiled.status != 0)
        {
            string msg = compiled.output.length ? compiled.output : "ldc2 failed";
            return RunResult(null, msg);
        }

        string loadError;
        lib = DynamicLibrary.open(dylibPath, loadError);
        if (!lib.loaded)
            return RunResult(null, loadError);

        alias RunFn = extern(C) void* function();
        alias ErrFn = extern(C) const(char)* function();
        auto runFn = cast(RunFn) lib.symbol("dcad_script_run");
        auto errFn = cast(ErrFn) lib.symbol("dcad_script_error");
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
        if (!lib.loaded) return 0;
        alias Fn = extern(C) int function();
        auto fn = cast(Fn) lib.symbol("dcad_anim_part_count");
        return fn is null ? 0 : fn();
    }

    /// Raw pointer to a part shape; valid until the next run() unloads the plugin.
    const(void)* animPartShape(int i)
    {
        if (!lib.loaded) return null;
        alias Fn = extern(C) const(void)* function(int);
        auto fn = cast(Fn) lib.symbol("dcad_anim_part_shape");
        return fn is null ? null : fn(i);
    }

    /// Display name for an animation part; valid until the next run().
    string animPartName(int i)
    {
        if (!lib.loaded) return null;
        alias Fn = extern(C) const(char)* function(int);
        auto fn = cast(Fn) lib.symbol("dcad_anim_part_name");
        if (fn is null) return null;
        auto p = fn(i);
        return p is null ? null : fromStringz(p).idup;
    }

    /// Stable id for an animation part, used to find its source module.
    string animPartId(int i)
    {
        if (!lib.loaded) return null;
        alias Fn = extern(C) const(char)* function(int);
        auto fn = cast(Fn) lib.symbol("dcad_anim_part_id");
        if (fn is null) return null;
        auto p = fn(i);
        return p is null ? null : fromStringz(p).idup;
    }

    /// 3 doubles (dx,dy,dz) per part at normalised time t.
    double[] animPose(double t, int count)
    {
        if (!lib.loaded || count <= 0) return null;
        alias Fn = extern(C) void function(double, double*);
        auto fn = cast(Fn) lib.symbol("dcad_anim_pose");
        if (fn is null) return null;
        auto offsets = new double[count * 3];
        fn(t, offsets.ptr);
        return offsets;
    }

private:
    void unload()
    {
        if (lib.loaded)
        {
            // Free C-owned animation buffers while the plugin is still loaded.
            alias FreeFn = extern(C) void function();
            auto freeFn = cast(FreeFn) lib.symbol("dcad_anim_free");
            if (freeFn !is null) freeFn();
            lib.close();
        }
    }

    void buildLinkArgs()
    {
        // Mirrors the host's dub.sdl flags so a plugin can instantiate shapes
        // through the same static shim and OCCT libraries.
        linkArgs = pluginLinkArgs(repoRoot);
    }
}

import std.string : fromStringz;
