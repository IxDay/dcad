/**
 * Project format and scaffolding.
 *
 * A project is a plain directory with a `.dcad.toml` marker and D sources.
 * The marker's directory is the project root, so `dcad-gui` accepts either the
 * directory, the marker file, or any source file inside it as its first
 * argument. Older `dcad.json` manifests are still read for compatibility.
 *
 * The same module creates File > New Project from the template embedded in the
 * runtime payload, so the menu and the command-line path cannot diverge.
 */
module gui.project;

import std.file : exists, isDir, mkdirRecurse, readText, write, dirEntries, SpanMode;
import std.json : parseJSON, JSONType;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
                  dirName, extension;
import std.process : execute;
import std.algorithm.searching : canFind, countUntil, endsWith, startsWith;
import std.string : strip, splitLines;

import gui.platform : resourceRoot;

/// Manifest names accepted as project markers. The first one is what New
/// Project writes; the others keep existing projects and early releases usable.
private enum string[] manifestNames = [".dcad.toml", "dcad.toml", "dcad.json"];

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

    /// Open a project from a directory, a marker file, or any source file
    /// inside a project. A bare source file is opened as the entry point.
    static Project open(string path)
    {
        auto resolved = absolutePath(path).buildNormalizedPath;
        Project result;
        string requestedSource;
        if (exists(resolved) && isDir(resolved))
        {
            result.root = resolved;
        }
        else
        {
            result.root = dirName(resolved);
            auto file = baseName(resolved);
            if (!isManifestName(file))
                requestedSource = file;
        }

        foreach (candidate; manifestNames)
        {
            immutable manifest = buildPath(result.root, candidate);
            if (exists(manifest))
            {
                result.readManifest(manifest);
                break;
            }
        }
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
            if (!item.isFile) continue;
            auto name = baseName(item.name);
            // Keep dotfiles such as .dcad.toml as well as normal sources.
            if (!extension(name).length && !name.startsWith(".")) continue;
            write(buildPath(target, name), readText(item.name));
        }

        Project result;
        result.root = target;
        immutable marker = buildPath(target, manifestNames[0]);
        enforce(exists(marker), "project template is missing " ~ marker);
        result.readManifest(marker);
        if (!result.name.length)
            result.name = baseName(target);
        return result;
    }

private:
    static bool isManifestName(string name)
    {
        foreach (candidate; manifestNames)
            if (name == candidate) return true;
        return false;
    }

    void readManifest(string path)
    {
        if (path.endsWith(".toml")) readToml(path);
        else readLegacyJson(path);
    }

    /// Minimal TOML reader for the flat key/value table we need. Values are
    /// basic strings; keys are `name`, `entry` and `description`. Anything
    /// else is ignored so future fields can be added without breaking the GUI.
    void readToml(string path)
    {
        foreach (raw; splitLines(readText(path)))
        {
            auto line = strip(raw);
            if (!line.length || line[0] == '#') continue;
            auto equal = countUntil(line, '=');
            if (equal < 0) continue;
            auto key = strip(line[0 .. equal]);
            auto value = unquoteToml(line[equal + 1 .. $]);
            switch (key)
            {
                case "name":        this.name = value; break;
                case "entry":       this.entry = value; break;
                case "description": this.description = value; break;
                default: break;
            }
        }
    }

    void readLegacyJson(string path)
    {
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

/// Strip TOML basic-string quotes and the escapes we emit in the template.
private string unquoteToml(string value)
{
    value = strip(value);
    if (value.length < 2 || value[0] != '"' || value[$-1] != '"')
        return value;
    auto inner = value[1 .. $-1];
    string result;
    for (size_t i = 0; i < inner.length; ++i)
    {
        if (inner[i] != '\\' || i + 1 == inner.length)
        {
            result ~= inner[i];
            continue;
        }
        ++i;
        switch (inner[i])
        {
            case 'n': result ~= '\n'; break;
            case 't': result ~= '\t'; break;
            case 'r': result ~= '\r'; break;
            case '"': result ~= '"'; break;
            case '\\': result ~= '\\'; break;
            default:  result ~= inner[i]; break;
        }
    }
    return result;
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

/// Choice presented by the native first-run modal. No project is opened by
/// default: the user either picks an existing one or scaffolds a new one.
enum ProjectChoice
{
    none,
    openExisting,
    createNew,
}

/// Ask for a directory with the platform's native folder picker. Returns null
/// on cancel or when no picker is installed; callers decide whether to fall
/// back to a documented directory or abort.
private string chooseFolder(string prompt)
{
    version (OSX)
    {
        auto result = execute([
            "osascript", "-e",
            `tell application "System Events" to activate`,
            "-e",
            `set dir to POSIX path of (choose folder with prompt "` ~ prompt ~ `")`,
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
        enum scriptHead =
            `Add-Type -AssemblyName System.Windows.Forms; ` ~
            `$d = New-Object System.Windows.Forms.FolderBrowserDialog; ` ~
            `$d.Description = '`;
        enum scriptTail =
            `'; ` ~
            `if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $d.SelectedPath }`;
        auto result = execute(["powershell.exe", "-NoProfile", "-STA",
                               "-Command", scriptHead ~ prompt ~ scriptTail]);
        if (result.status == 0)
        {
            auto path = strip(result.output);
            if (path.length) return path;
        }
    }
    else
    {
        auto zenity = execute(["zenity", "--directory", "--title=" ~ prompt]);
        if (zenity.status == 0)
        {
            auto path = strip(zenity.output);
            if (path.length) return path;
        }
        auto kdialog = execute(["kdialog", "--getexistingdirectory",
                                "--title", prompt]);
        if (kdialog.status == 0)
        {
            auto path = strip(kdialog.output);
            if (path.length) return path;
        }
    }
    return null;
}

/// Ask where a new project should be created.
string chooseProjectParent()
{
    return chooseFolder("Choose a folder for the new D/OCCT project");
}

/// Ask which existing project directory to open.
string chooseExistingProject()
{
    return chooseFolder("Choose an existing dcad project folder");
}

/// Native modal shown when no project was supplied or found in the launch
/// directory. Cancelling returns `ProjectChoice.none`.
ProjectChoice askProjectChoice()
{
    version (OSX)
    {
        auto result = execute(["osascript", "-e",
            `display dialog "dcad needs a project. Open an existing project, or create a new one?" ` ~
            `buttons {"Open Existing", "Create New", "Cancel"} ` ~
            `default button "Open Existing" cancel button "Cancel"`]);
        if (result.status != 0) return ProjectChoice.none;
        auto answer = strip(result.output);
        if (answer.canFind("Create New")) return ProjectChoice.createNew;
        if (answer.canFind("Open Existing")) return ProjectChoice.openExisting;
    }
    else version (Windows)
    {
        enum script =
            `Add-Type -AssemblyName System.Windows.Forms; ` ~
            `$r = [System.Windows.Forms.MessageBox]::Show(` ~
            `'dcad needs a project. Open an existing project, or create a new one?', ` ~
            `'dcad', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, ` ~
            `[System.Windows.Forms.MessageBoxIcon]::Question); ` ~
            `if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Write-Output 'open' } ` ~
            `elseif ($r -eq [System.Windows.Forms.DialogResult]::No) { Write-Output 'new' }`;
        auto result = execute(["powershell.exe", "-NoProfile", "-STA",
                               "-Command", script]);
        if (result.status == 0)
        {
            auto answer = strip(result.output);
            if (answer == "open") return ProjectChoice.openExisting;
            if (answer == "new") return ProjectChoice.createNew;
        }
    }
    else
    {
        auto zenity = execute(["zenity", "--question",
                               "--title=dcad",
                               "--text=Open an existing dcad project, or create a new one?",
                               "--ok-label=Open Existing",
                               "--cancel-label=Create New"]);
        if (zenity.status == 0) return ProjectChoice.openExisting;
        if (zenity.status == 1) return ProjectChoice.createNew;

        auto kdialog = execute(["kdialog", "--yesno",
                                "Open an existing dcad project?"]);
        if (kdialog.status == 0) return ProjectChoice.openExisting;
        if (kdialog.status == 1) return ProjectChoice.createNew;
    }
    return ProjectChoice.none;
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
