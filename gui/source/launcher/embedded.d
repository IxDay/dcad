/**
 * Runtime payload embedded in the released launcher binary.
 *
 * The payload is a ZIP produced by tools/build_resources.py and linked into
 * the launcher. On first launch it expands into a versioned cache under the
 * user's data directory; the real GUI is then started from that directory,
 * where its assets, D SDK and native libraries sit exactly where a source
 * checkout would put them. Nothing is written into the opened project.
 */
module launcher.embedded;

import std.file : exists, mkdirRecurse, readText, remove, rename, write,
                  rmdirRecurse;
import std.path : buildPath, dirName;
import std.zip : ZipArchive;
import std.conv : to;
import std.string : toStringz, fromStringz, strip;

/// Where the extracted runtime lives, and whether it has native libraries.
struct ResourceState
{
    bool embedded;
    bool hasLibraries;
    string root;
    string versionTag;
}

version (Windows)
{
    extern(C) nothrow @nogc
    {
        void* GetModuleHandleA(const(char)*);
        void* FindResourceA(void*, const(char)*, const(char)*);
        uint SizeofResource(void*, void*);
        void* LoadResource(void*, void*);
        void* LockResource(void*);
    }
}
else version (OSX)
{
    // ld -r -b binary emits these C symbols for dcad_payload.bin.
    extern(C) extern __gshared ubyte binary_dcad_payload_bin_start;
    extern(C) extern __gshared ubyte binary_dcad_payload_bin_end;
}
else version (linux)
{
    extern(C) extern __gshared ubyte _binary_dcad_payload_bin_start;
    extern(C) extern __gshared ubyte _binary_dcad_payload_bin_end;
}

/// Access the linked payload without copying it.
const(ubyte)[] payloadBytes()
{
    version (Windows)
    {
        auto module_ = GetModuleHandleA(null);
        if (module_ is null) return null;
        // MAKEINTRESOURCE(1) for the id and RT_RCDATA (10) for the type:
        // both are integer values, not the strings "1" and "RCDATA".
        auto resource = FindResourceA(module_, cast(const(char)*) 1,
                                      cast(const(char)*) 10);
        if (resource is null) return null;
        immutable size = SizeofResource(module_, resource);
        if (size == 0) return null;
        auto data = LoadResource(module_, resource);
        auto bytes = LockResource(data);
        if (bytes is null) return null;
        return (cast(const(ubyte)*) bytes)[0 .. size];
    }
    else version (OSX)
        return (&binary_dcad_payload_bin_start)[0 ..
            &binary_dcad_payload_bin_end - &binary_dcad_payload_bin_start];
    else version (linux)
        return (&_binary_dcad_payload_bin_start)[0 ..
            &_binary_dcad_payload_bin_end - &_binary_dcad_payload_bin_start];
    else
        return null;
}

/// The payload carries a tiny build marker. Reading that one ZIP member is
/// much cheaper than hashing the whole embedded archive on every launch.
/// Older archives without the marker fall back to a bounded sample hash.
private string versionTag(const(ubyte)[] bytes)
{
    try
    {
        auto zip = new ZipArchive(cast(void[]) bytes);
        if (auto member = "dcad-version.txt" in zip.directory)
        {
            zip.expand(*member);
            auto text = cast(string) member.expandedData;
            if (text.length)
                return text.strip.idup;
        }
    }
    catch (Exception)
    {
        // Corrupt marker: fall through to the bounded hash below.
    }

    enum sampleSize = 65536;
    ulong hash = 1469598103934665603UL;
    void mix(ubyte b)
    {
        hash ^= b;
        hash *= 1099511628211UL;
    }
    foreach (b; bytes[0 .. bytes.length < sampleSize ? bytes.length : sampleSize])
        mix(b);
    if (bytes.length > sampleSize)
        foreach (b; bytes[$ - sampleSize .. $])
            mix(b);
    foreach (b; bytes.length.to!string)
        mix(cast(ubyte) b);
    return hash.to!string;
}

private string cacheBase()
{
    version (Windows)
    {
        import core.stdc.stdlib : getenv;

        if (auto local = getenv("LOCALAPPDATA".toStringz))
            return buildPath(fromStringz(local).idup, "dcad", "runtime");
    }
    else version (Posix)
    {
        import core.stdc.stdlib : getenv;

        if (auto xdg = getenv("XDG_CACHE_HOME".toStringz))
        {
            auto path = fromStringz(xdg).idup;
            if (path.length) return buildPath(path, "dcad");
        }
        if (auto home = getenv("HOME".toStringz))
            return buildPath(fromStringz(home).idup, ".cache", "dcad");
    }
    return buildPath("/tmp", "dcad-runtime");
}

/// A cache can be marked current while a previous extraction was interrupted
/// or partially cleaned. Check a few files the GUI always needs so that such
/// a cache repairs itself instead of reporting missing icons and fonts.
private bool runtimeComplete(string root)
{
    return exists(buildPath(root, "assets", "icons", "refresh.png")) &&
           exists(buildPath(root, "assets", "MesloLGS_NF_Regular.ttf")) &&
           exists(buildPath(root, "samples", "coffee-table", "table.d"));
}

/// Extract the payload if needed and return its resolved directory.
ResourceState prepareResources()
{
    ResourceState state;
    auto bytes = payloadBytes();
    // An empty payload is produced for local development builds, where the
    // repository itself is the resource root.
    if (bytes.length < 1024)
        return state;

    state.embedded = true;
    state.versionTag = versionTag(bytes);
    state.root = buildPath(cacheBase(), "v" ~ state.versionTag);

    auto marker = buildPath(state.root, "resource-version.txt");
    if (!exists(marker) || readText(marker) != state.versionTag ||
        !runtimeComplete(state.root))
        extract(bytes, state.root, state.versionTag);

    auto manifest = buildPath(state.root, "embedded.manifest");
    if (exists(manifest))
        state.hasLibraries = readText(manifest).indexOf("libs=1") >= 0;
    return state;
}

private long indexOf(string haystack, string needle)
{
    import std.algorithm.searching : countUntil;
    return countUntil(haystack, needle);
}

private void extract(const(ubyte)[] bytes, string root, string tag)
{
    import std.file : remove;

    // Build in a private directory, then swap it in. A second process that
    // sees the old cache keeps using its own files until the rename.
    version (Windows)
        import core.sys.windows.windows : GetCurrentProcessId;
    else
        import core.sys.posix.unistd : getpid;

    version (Windows)
        immutable pid = GetCurrentProcessId().to!string;
    else
        immutable pid = getpid().to!string;
    auto staging = root ~ ".extract-" ~ pid;
    if (exists(staging)) rmdirRecurse(staging);
    mkdirRecurse(staging);

    auto zip = new ZipArchive(cast(void[]) bytes.dup);
    foreach (name, member; zip.directory)
    {
        if (name.length == 0) continue;
        auto target = buildPath(staging, name);
        if (name[$ - 1] == '/')
        {
            mkdirRecurse(target);
            continue;
        }
        mkdirRecurse(dirName(target));
        zip.expand(member);
        write(target, member.expandedData);
    }
    write(buildPath(staging, "resource-version.txt"), tag);

    if (exists(root)) rmdirRecurse(root);
    rename(staging, root);
}
