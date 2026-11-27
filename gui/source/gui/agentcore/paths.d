/**
 * Filesystem locations used by the embedded agent.
 *
 * Sessions and patches live in the project's .dcad directory. Credentials and
 * transient config stay in dcad's app cache and are never written into a
 * project.
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

string agentConfigDir()
{
    auto overrideDir = environment.get("DCAD_AGENT_CONFIG_DIR", "");
    if (overrideDir.length) return overrideDir;
    return buildPath(agentAppCacheDir(), "config");
}

string agentCredentialsPath()
{
    return buildPath(agentConfigDir(), "credentials.json");
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
