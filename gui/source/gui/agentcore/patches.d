/**
 * Project-owned diff and revert state for the embedded agent.
 *
 * Patches are staged under `.dcad/patches/` using upstream-shaped revert
 * events. The sibling JSON metadata keeps exact before/after snapshots so undo
 * is byte-for-byte even when a file lacks a trailing newline.
 */
module gui.agentcore.patches;

import std.algorithm : min, startsWith;
import std.datetime.systime : Clock;
import std.file : dirEntries, exists, isDir, mkdirRecurse, readText, remove, write, SpanMode;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, dirName, extension;
import std.string : join, splitLines;

import gui.agentcore.paths : agentPatchesDir;
import gui.agentcore.schema : agentBoolField, agentField, agentStringField,
                              agentUnsignedField;

version (Windows) private enum pathSep = "\\";
else private enum pathSep = "/";

struct AgentFileDiff
{
    string file;
    string patch;
    size_t additions;
    size_t deletions;
    string status;
    string before;
    string after;
    bool beforeExists;
    bool afterExists = true;

    JSONValue toJSON()
    {
        JSONValue[string] object;
        object["file"] = JSONValue(file);
        object["patch"] = JSONValue(patch);
        object["additions"] = JSONValue(cast(long) additions);
        object["deletions"] = JSONValue(cast(long) deletions);
        object["status"] = JSONValue(status);
        object["before"] = JSONValue(before);
        object["after"] = JSONValue(after);
        object["beforeExists"] = JSONValue(beforeExists);
        object["afterExists"] = JSONValue(afterExists);
        return JSONValue(object);
    }

    static AgentFileDiff fromJSON(JSONValue value)
    {
        AgentFileDiff result;
        result.file = agentStringField(value, "file");
        result.patch = agentStringField(value, "patch");
        result.additions = cast(size_t) agentUnsignedField(value, "additions");
        result.deletions = cast(size_t) agentUnsignedField(value, "deletions");
        result.status = agentStringField(value, "status", "modified");
        result.before = agentStringField(value, "before");
        result.after = agentStringField(value, "after");
        result.beforeExists = agentBoolField(value, "beforeExists");
        result.afterExists = agentBoolField(value, "afterExists", true);
        return result;
    }
}

struct AgentPatchSet
{
    string id;
    string messageID;
    long created;
    AgentFileDiff[] files;

    JSONValue toJSON()
    {
        JSONValue[] encoded;
        foreach (file; files) encoded ~= file.toJSON();

        JSONValue[string] object;
        object["id"] = JSONValue(id);
        object["messageID"] = JSONValue(messageID);
        object["created"] = JSONValue(created);
        object["files"] = JSONValue(encoded);
        return JSONValue(object);
    }

    static AgentPatchSet fromJSON(JSONValue value)
    {
        AgentPatchSet result;
        result.id = agentStringField(value, "id");
        result.messageID = agentStringField(value, "messageID");
        result.created = cast(long) agentUnsignedField(value, "created");
        auto files = agentField(value, "files");
        if (files.type == JSONType.array)
            foreach (file; files.array)
                result.files ~= AgentFileDiff.fromJSON(file);
        return result;
    }
}

private struct ContentSnapshot
{
    bool exists;
    string text;
}

/// Captures original file contents before project tools mutate them.
final class AgentChangeRecorder
{
    private string root;
    private ContentSnapshot[string] snapshots;

    this(string projectRoot)
    {
        root = absolutePath(projectRoot);
        while (root.length > 1 && root[$ - 1] == pathSep[0])
            root = root[0 .. $ - 1];
    }

    void capture(string relative)
    {
        if (!relative.length || relative in snapshots) return;
        auto path = resolve(root, relative);
        if (!path.length) return;

        ContentSnapshot snapshot;
        snapshot.exists = exists(path);
        if (snapshot.exists) snapshot.text = readText(path);
        snapshots[relative.idup] = snapshot;
    }

    /// Snapshot every existing project file before an unrestricted tool such
    /// as shell runs. `.dcad/` is agent state and is never part of a diff.
    void captureAll()
    {
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            if (entry.isDir || baseName(entry.name) == ".dcad") continue;
            auto relative = entry.name[root.length .. $];
            while (relative.length && (relative[0] == '/' || relative[0] == '\\'))
                relative = relative[1 .. $];
            capture(relative);
        }
    }

    /// Record files created by an unrestricted tool as absent-before changes.
    void captureMissing()
    {
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            if (entry.isDir || baseName(entry.name) == ".dcad") continue;
            auto relative = entry.name[root.length .. $];
            while (relative.length && (relative[0] == '/' || relative[0] == '\\'))
                relative = relative[1 .. $];
            if (relative in snapshots) continue;

            snapshots[relative.idup] = ContentSnapshot(false, null);
        }
    }

    bool hasChanges() const @property
    {
        return snapshots.length != 0;
    }

    AgentFileDiff[] diffs()
    {
        AgentFileDiff[] result;
        foreach (relative, snapshot; snapshots)
        {
            auto path = resolve(root, relative);
            if (!path.length) continue;

            ContentSnapshot current;
            current.exists = exists(path);
            if (current.exists) current.text = readText(path);
            if (snapshot.exists == current.exists && snapshot.text == current.text)
                continue;

            result ~= diffFile(relative, snapshot, current);
        }
        return result;
    }

    private static string resolve(string root, string relative)
    {
        auto full = absolutePath(buildPath(root, relative));
        if (full != root && !full.startsWith(root ~ pathSep)) return null;
        return full;
    }
}

string makeAgentPatchID()
{
    import std.conv : to;
    return "change-" ~ Clock.currTime().toUnixTime().to!string ~ "-"
        ~ Clock.currTime().toISOString().to!string;
}

string sanitizePatchID(string id)
{
    string result;
    foreach (ch; id)
    {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9') || ch == '-' || ch == '_')
            result ~= ch;
    }
    return result.length ? result : "change";
}

private AgentFileDiff diffFile(string file, ContentSnapshot before,
                               ContentSnapshot after)
{
    AgentFileDiff result;
    result.file = file;
    result.before = before.text;
    result.after = after.text;
    result.beforeExists = before.exists;
    result.afterExists = after.exists;

    if (!before.exists)
        result.status = "added";
    else if (!after.exists)
        result.status = "deleted";
    else
        result.status = "modified";

    auto oldLines = before.exists ? splitLines(before.text) : null;
    auto newLines = after.exists ? splitLines(after.text) : null;

    size_t prefix;
    while (prefix < oldLines.length && prefix < newLines.length &&
           oldLines[prefix] == newLines[prefix])
        ++prefix;

    size_t suffix;
    while (suffix < oldLines.length - prefix && suffix < newLines.length - prefix &&
           oldLines[oldLines.length - 1 - suffix] ==
           newLines[newLines.length - 1 - suffix])
        ++suffix;

    immutable context = 3;
    auto lead = min(prefix, context);
    auto trail = min(suffix, context);
    auto oldStart = prefix - lead;
    auto newStart = prefix - lead;

    string[] body;
    foreach (line; oldLines[oldStart .. prefix])
        body ~= " " ~ line;
    foreach (line; oldLines[prefix .. oldLines.length - suffix])
    {
        body ~= "-" ~ line;
        ++result.deletions;
    }
    foreach (line; newLines[prefix .. newLines.length - suffix])
    {
        body ~= "+" ~ line;
        ++result.additions;
    }
    foreach (line; newLines[newStart .. prefix])
        body ~= " " ~ line;
    foreach (line; newLines[newLines.length - suffix - trail .. newLines.length - suffix])
        body ~= " " ~ line;

    auto oldCount = (prefix - oldStart) +
                    (oldLines.length - prefix - suffix) + trail;
    auto newCount = (prefix - newStart) +
                    (newLines.length - prefix - suffix) + trail;
    import std.conv : to;
    result.patch = "--- a/" ~ file ~ "\n+++ b/" ~ file ~ "\n"
        ~ "@@ -" ~ (oldCount ? (oldStart + 1).to!string : "0") ~ ","
        ~ oldCount.to!string ~ " +"
        ~ (newCount ? (newStart + 1).to!string : "0") ~ ","
        ~ newCount.to!string ~ " @@\n"
        ~ body.join("\n") ~ (body.length ? "\n" : "");
    return result;
}

final class AgentPatchStore
{
    private string root;

    this(string projectRoot)
    {
        root = projectRoot;
    }

    AgentPatchSet stage(AgentChangeRecorder recorder, string messageID)
    {
        auto files = recorder.diffs();
        if (!files.length) return AgentPatchSet.init;

        AgentPatchSet set;
        set.id = makeAgentPatchID();
        set.messageID = messageID.length ? messageID : set.id;
        set.created = Clock.currTime().toUnixTime();
        set.files = files;
        save(set);
        return set;
    }

    void save(AgentPatchSet set)
    {
        if (!set.files.length) return;
        mkdirRecurse(agentPatchesDir(root));

        string combined;
        foreach (file; set.files)
            combined ~= "diff --git a/" ~ file.file ~ " b/" ~ file.file ~ "\n"
                ~ file.patch;
        write(patchPath(set.id), combined);
        write(metadataPath(set.id), set.toJSON().toString());
    }

    AgentPatchSet load(string id)
    {
        auto path = metadataPath(id);
        if (!id.length || !exists(path)) return AgentPatchSet.init;
        try return AgentPatchSet.fromJSON(parseJSON(readText(path)));
        catch (Exception) return AgentPatchSet.init;
    }

    AgentPatchSet latest()
    {
        AgentPatchSet[] sets = list();
        if (!sets.length) return AgentPatchSet.init;
        AgentPatchSet newest = sets[0];
        foreach (set; sets)
            if (set.created >= newest.created) newest = set;
        return newest;
    }

    AgentPatchSet[] list()
    {
        AgentPatchSet[] result;
        auto dir = agentPatchesDir(root);
        if (!exists(dir)) return result;
        foreach (entry; dirEntries(dir, "*.json", SpanMode.shallow))
        {
            if (extension(entry.name) != ".json") continue;
            try
            {
                auto set = AgentPatchSet.fromJSON(parseJSON(readText(entry.name)));
                if (set.id.length) result ~= set;
            }
            catch (Exception) { /* ignore corrupt metadata */ }
        }
        return result;
    }

    bool undo(string id)
    {
        auto set = load(id);
        if (!set.id.length) return false;

        foreach (file; set.files)
        {
            auto path = resolve(root, file.file);
            if (!path.length) continue;
            if (file.beforeExists)
            {
                mkdirRecurse(dirName(path));
                write(path, file.before);
            }
            else if (exists(path))
                remove(path);
        }
        discard(id);
        return true;
    }

    bool clear(string id)
    {
        auto set = load(id);
        if (!set.id.length) return false;
        discard(id);
        return true;
    }

    string patchText(string id)
    {
        auto path = patchPath(id);
        if (!exists(path)) return "";
        try return readText(path);
        catch (Exception) return "";
    }

    private string patchPath(string id)
    {
        return buildPath(agentPatchesDir(root), sanitizePatchID(id) ~ ".patch");
    }

    private string metadataPath(string id)
    {
        return buildPath(agentPatchesDir(root), sanitizePatchID(id) ~ ".json");
    }

    private void discard(string id)
    {
        auto patch = patchPath(id);
        auto metadata = metadataPath(id);
        if (exists(patch)) remove(patch);
        if (exists(metadata)) remove(metadata);
    }

    private static string resolve(string root, string relative)
    {
        auto absoluteRoot = absolutePath(root);
        auto full = absolutePath(buildPath(absoluteRoot, relative));
        if (full != absoluteRoot && !full.startsWith(absoluteRoot ~ pathSep))
            return null;
        return full;
    }
}

JSONValue revertEventData(AgentPatchSet set)
{
    JSONValue[string] revert;
    revert["messageID"] = JSONValue(set.messageID);
    if (set.id.length) revert["snapshot"] = JSONValue(set.id);

    JSONValue[] files;
    foreach (file; set.files)
    {
        JSONValue[string] entry;
        entry["file"] = JSONValue(file.file);
        entry["patch"] = JSONValue(file.patch);
        entry["additions"] = JSONValue(cast(long) file.additions);
        entry["deletions"] = JSONValue(cast(long) file.deletions);
        entry["status"] = JSONValue(file.status);
        files ~= JSONValue(entry);
    }
    revert["files"] = JSONValue(files);

    JSONValue[string] data;
    data["revert"] = JSONValue(revert);
    return JSONValue(data);
}
