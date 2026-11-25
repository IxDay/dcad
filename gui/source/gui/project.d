/**
 * Project format and scaffolding.
 *
 * A project is a plain directory with a `dcad.json` manifest and D sources.
 * `dcad-gui` accepts either the directory or the manifest as its first
 * argument, which makes the released binary usable as a project handler.
 *
 * The same module creates File > New Project from the template embedded in the
 * runtime payload, so the menu and the command-line path cannot diverge.
 */
module gui.project;

import std.file : exists, isDir, mkdirRecurse, readText, write, dirEntries, SpanMode;
import std.json : parseJSON, JSONType;
import std.path : absolutePath, baseName, buildPath, dirName, extension;
import std.process : execute;
import std.string : strip;

import gui.platform : resourceRoot;

/// Parsed project manifest.
struct Project
{
    /// Absolute project directory.
    string root;

    /// Human-readable name from the manifest (or the directory name).
    string name;

    /// Source opened on launch, relative to `root`.
    string entry = "main.d";

    string description;

    /// Absolute path of the assembly entry source.
    string entryPath() const
    {
        return buildPath(root, entry);
    }

    /// Open a project from a directory, a `dcad.json` file, or any source file
    /// inside a project. A bare source file is opened as the entry point.
    static Project open(string path)
    {
        auto resolved = absolutePath(path);
        Project result;
        string requestedSource;
        if (exists(resolved) && isDir(resolved))
        {
            result.root = resolved;
        }
        else
        {
            result.root = dirName(resolved);
            if (baseName(resolved) != "dcad.json")
                requestedSource = baseName(resolved);
        }

        immutable manifest = buildPath(result.root, "dcad.json");
        if (exists(manifest))
            result.readManifest(manifest);
        // An explicitly named source wins over the manifest's default entry.
        if (requestedSource.length)
            result.entry = requestedSource;
        if (!result.name.length)
            result.name = baseName(result.root);
        if (!result.entry.length)
            result.entry = "main.d";
        immutable entryPath = buildPath(result.root, result.entry);
        if (!exists(entryPath))
            throw new Exception("source not found: " ~ entryPath);
        return result;
    }

    /// Copy the bundled template into `target`. The target must not exist.
    static Project create(string target, string templateRoot)
    {
        import std.exception : enforce;

        target = absolutePath(target);
        enforce(!exists(target), "project directory already exists: " ~ target);
        immutable source = buildPath(templateRoot, "project-template", "daimochi");
        enforce(exists(source), "project template is missing: " ~ source);

        mkdirRecurse(target);
        foreach (item; dirEntries(source, SpanMode.shallow))
        {
            if (!item.isFile || extension(item.name).length == 0)
                continue;
            write(buildPath(target, baseName(item.name)), readText(item.name));
        }

        Project result;
        result.root = target;
        result.readManifest(buildPath(target, "dcad.json"));
        if (!result.name.length)
            result.name = baseName(target);
        return result;
    }

private:
    void readManifest(string path)
    {
        import std.string : fromStringz;

        auto json = parseJSON(readText(path));
        if (json.type != JSONType.object)
            return;
        if (auto name = "name" in json)
            if (name.type == JSONType.string)
                this.name = name.str;
        if (auto entry = "entry" in json)
            if (entry.type == JSONType.string)
                this.entry = entry.str;
        if (auto description = "description" in json)
            if (description.type == JSONType.string)
                this.description = description.str;
    }
}

/// Make a non-existing sibling of `parent`, e.g. `daimochi-tsugi-1`.
string uniqueProjectPath(string parent, string baseName_)
{
    import std.conv : to;

    auto candidate = buildPath(parent, baseName_);
    for (int index = 1; exists(candidate); ++index)
        candidate = buildPath(parent, baseName_ ~ "-" ~ index.to!string);
    return candidate;
}

/// Ask for a parent directory with the platform's native folder picker.
/// Returns null on cancel or when no picker is installed; the caller then uses
/// a documented fallback directory instead of guessing inside the repo.
string chooseProjectParent()
{
    version (OSX)
    {
        auto result = execute([
            "osascript", "-e",
            `tell application "System Events" to activate`,
            "-e",
            `set dir to POSIX path of (choose folder with prompt "Choose a folder for the new D/OCCT project")`,
            "-e", `return dir`,
        ]);
        if (result.status == 0)
        {
            auto path = strip(result.output);
            if (path.length) return path;
        }
    }
    else version (Windows)
    {
        enum script =
            `Add-Type -AssemblyName System.Windows.Forms; ` ~
            `$d = New-Object System.Windows.Forms.FolderBrowserDialog; ` ~
            `$d.Description = 'Choose a folder for the new D/OCCT project'; ` ~
            `if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $d.SelectedPath }`;
        auto result = execute(["powershell.exe", "-NoProfile", "-STA",
                               "-Command", script]);
        if (result.status == 0)
        {
            auto path = strip(result.output);
            if (path.length) return path;
        }
    }
    else
    {
        auto zenity = execute(["zenity", "--directory",
                               "--title=New D/OCCT project"]);
        if (zenity.status == 0)
        {
            auto path = strip(zenity.output);
            if (path.length) return path;
        }
        auto kdialog = execute(["kdialog", "--getexistingdirectory"]);
        if (kdialog.status == 0)
        {
            auto path = strip(kdialog.output);
            if (path.length) return path;
        }
    }
    return null;
}

/// Default location used when the folder picker is cancelled or unavailable.
string fallbackProjectParent()
{
    import std.file : getcwd;

    version (Windows)
    {
        if (auto local = env("LOCALAPPDATA"))
            return buildPath(local, "dcad", "projects");
    }
    else version (Posix)
    {
        if (auto home = env("HOME"))
            return buildPath(home, "dcad-projects");
    }
    return getcwd();
}

private string env(string name)
{
    import core.stdc.stdlib : getenv;
    import std.string : fromStringz, toStringz;

    const value = getenv(name.toStringz);
    return value is null ? null : fromStringz(value).idup;
}
