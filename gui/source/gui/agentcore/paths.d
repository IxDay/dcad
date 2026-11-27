/**
 * Filesystem locations used by the embedded agent.
 *
 * Sessions, reversible patches and agent config all live in the project's
 * `.dcad` directory. `DCAD_AGENT_CONFIG_DIR` can relocate the config for
 * automation; without a project root the app cache is used as a safe fallback
 * for headless tests.
 */
module gui.agentcore.paths;

import std.file : tempDir;
import std.path : buildPath;
import std.process : environment;

string agentAppCacheDir()
{
    version (Windows)
    {
        auto local = environment.get("LOCALAPPDATA", "");
        if (local.length) return buildPath(local, "dcad", "agent");
        auto profile = environment.get("USERPROFILE", "");
        if (profile.length)
            return buildPath(profile, "AppData", "Local", "dcad", "agent");
    }
    else version (OSX)
    {
        auto home = environment.get("HOME", "");
        if (home.length) return buildPath(home, "Library", "Caches", "dcad", "agent");
    }
    else
    {
        auto xdg = environment.get("XDG_CACHE_HOME", "");
        if (xdg.length) return buildPath(xdg, "dcad", "agent");
        auto home = environment.get("HOME", "");
        if (home.length) return buildPath(home, ".cache", "dcad", "agent");
    }

    return buildPath(tempDir(), "dcad-agent-cache");
}

/// Directory containing config.toml for a project. The override keeps CI and
/// embedded tests independent of the developer's projects.
string agentConfigDir(string projectRoot = "")
{
    auto overrideDir = environment.get("DCAD_AGENT_CONFIG_DIR", "");
    if (overrideDir.length) return overrideDir;
    if (projectRoot.length) return buildPath(projectRoot, ".dcad");
    return buildPath(agentAppCacheDir(), "config");
}

string agentConfigPath(string projectRoot = "")
{
    return buildPath(agentConfigDir(projectRoot), "config.toml");
}

string agentHistoryDir(string projectRoot)
{
    return buildPath(projectRoot, ".dcad");
}

string agentHistoryPath(string projectRoot)
{
    return buildPath(agentHistoryDir(projectRoot), "history.jsonl");
}

string agentPatchesDir(string projectRoot)
{
    return buildPath(agentHistoryDir(projectRoot), "patches");
}
