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
                  rmdirRecurse, symlink;
import std.path : buildPath, dirName;
import std.zip : ZipArchive;
import std.conv : to;
import std.string : toStringz, fromStringz;

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
        // MAKEINTRESOURCE(1): the low word is the integer id, not text "1".
        auto resource = FindResourceA(module_, cast(const(char)*) 1,
                                      "RCDATA".toStringz);
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

/// FNV-1a over the payload gives each distinct build its own cache directory.
private string versionTag(const(ubyte)[] bytes)
{
    ulong hash = 1469598103934665603UL;
    foreach (b; bytes)
    {
        hash ^= b;
        hash *= 1099511628211UL;
    }
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
    if (!exists(marker) || readText(marker) != state.versionTag)
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
        version (Posix)
        {
            // Python stores short library names as symlinks, avoiding a
            // duplicate copy of every versioned dylib in the payload.
            immutable attrs = member.fileAttributes;
            if ((attrs & 0xF000) == 0xA000)
            {
                symlink(cast(string) member.expandedData.idup, target);
                continue;
            }
        }
        write(target, member.expandedData);
    }
    write(buildPath(staging, "resource-version.txt"), tag);

    if (exists(root)) rmdirRecurse(root);
    rename(staging, root);
}
