/**
 * In-UI OpenCode agent bridge.
 *
 * The Agent tab runs the installed `opencode` CLI with the open project as the
 * working directory, so the agent gets the same files, configuration,
 * credentials and tools as a terminal session. JSON events are streamed back
 * through a reader thread and drained on the GUI thread.
 *
 * Session IDs and UI transcripts are kept only in dcad's app cache. Nothing is
 * written into the open project.
 */
module gui.agent;

import std.algorithm : startsWith;
import core.sync.mutex : Mutex;
import core.thread.osthread : Thread;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, readText, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Config, Pid, Redirect, environment, pipeProcess, wait, kill;
import std.stdio : File;
import std.string : strip;

enum AgentRole
{
    user,
    assistant,
    tool,
    error,
    status
}

struct AgentMessage
{
    AgentRole role;
    string text;
    string key;
}

/// Messages sent from the CLI reader thread to the GUI thread.
private struct AgentPipeLine
{
    ulong generation;
    string text;
}

private struct AgentProcessDone
{
    ulong generation;
    int code;
    string error;
}

/// Thread-safe mailbox between the CLI reader thread and the GUI thread.
private final class AgentChannel
{
    private Mutex mutex;
    private AgentPipeLine[] lines;
    private AgentProcessDone[] results;

    this()
    {
        mutex = new Mutex();
    }

    void pushLine(ulong generation, string text)
    {
        synchronized (mutex)
            lines ~= AgentPipeLine(generation, text);
    }

    void pushDone(ulong generation, int code, string error)
    {
        synchronized (mutex)
            results ~= AgentProcessDone(generation, code, error);
    }

    void take(ref AgentPipeLine[] outLines, ref AgentProcessDone[] outResults)
    {
        synchronized (mutex)
        {
            outLines = lines;
            outResults = results;
            lines = null;
            results = null;
        }
    }
}

/// Owns the child's output handle on the reader thread. Keeping it in a class
/// instance avoids capturing a stack local that vanishes when send() returns.
private final class AgentWorkerState
{
    File output;
    Pid pid;
    ulong generation;
    AgentChannel channel;

    this(File output, Pid pid, ulong generation, AgentChannel channel)
    {
        this.output = output;
        this.pid = pid;
        this.generation = generation;
        this.channel = channel;
    }

    void run()
    {
        try
        {
            foreach (line; output.byLine())
                channel.pushLine(generation, line.idup);
            channel.pushDone(generation, wait(pid), null);
        }
        catch (Exception e)
            channel.pushDone(generation, -1, e.msg);
    }
}

private ulong fnv1a(string text)
{
    ulong hash = 14_695_981_039_346_656_037UL;
    foreach (ubyte c; text)
    {
        hash ^= c;
        hash *= 1_099_511_628_211UL;
    }
    return hash;
}

private string hex(ulong value)
{
    enum digits = "0123456789abcdef";
    char[16] outBuf = void;
    foreach (i; 0 .. 16)
        outBuf[15 - i] = digits[(value >> (i * 4)) & 0xf];
    return outBuf.idup;
}

/// Directory used for agent session metadata and transcripts. Never the project.
string agentCacheDir()
{
    version (Windows)
    {
        import std.process : environment;

        auto local = environment.get("LOCALAPPDATA", "");
        if (local.length) return buildPath(local, "dcad", "agent");
        auto profile = environment.get("USERPROFILE", "");
        if (profile.length)
            return buildPath(profile, "AppData", "Local", "dcad", "agent");
    }
    else version (OSX)
    {
        import std.process : environment;

        auto home = environment.get("HOME", "");
        if (home.length) return buildPath(home, "Library", "Caches", "dcad", "agent");
    }
    else
    {
        import std.process : environment;

        auto xdg = environment.get("XDG_CACHE_HOME", "");
        if (xdg.length) return buildPath(xdg, "dcad", "agent");
        auto home = environment.get("HOME", "");
        if (home.length) return buildPath(home, ".cache", "dcad", "agent");
    }

    // Still outside the project if the platform exposes no home directory.
    import std.file : tempDir;

    return buildPath(tempDir(), "dcad-agent-cache");
}

private string agentCachePath(string projectRoot)
{
    return buildPath(agentCacheDir(), hex(fnv1a(projectRoot)) ~ ".json");
}

string makeSessionId(string projectRoot, ulong stamp)
{
    return "ses_dcad_" ~ hex(fnv1a(projectRoot)) ~ "_" ~ hex(stamp);
}

private JSONValue jsonField(JSONValue value, string key)
{
    if (value.type == JSONType.object)
    {
        if (auto found = key in value.object)
            return *found;
    }
    return JSONValue.init;
}

private string jsonText(JSONValue value)
{
    if (value.type == JSONType.null_) return null;
    return value.type == JSONType.string ? value.str : value.toString();
}

private string jsonFieldText(JSONValue value, string key)
{
    return jsonText(jsonField(value, key));
}

private void appendMessage(ref AgentMessage[] messages, AgentMessage message)
{
    messages ~= message;
    if (messages.length > 500)
        messages = messages[$ - 500 .. $];
}

private string truncate(string text, size_t limit)
{
    return text.length > limit ? text[0 .. limit] ~ "..." : text;
}

private string roleName(AgentRole role)
{
    final switch (role)
    {
        case AgentRole.user:      return "user";
        case AgentRole.assistant: return "assistant";
        case AgentRole.tool:      return "tool";
        case AgentRole.error:     return "error";
        case AgentRole.status:    return "status";
    }
}

private AgentRole parseRole(string name)
{
    switch (name)
    {
        case "user":      return AgentRole.user;
        case "assistant": return AgentRole.assistant;
        case "tool":      return AgentRole.tool;
        case "error":     return AgentRole.error;
        default:          return AgentRole.status;
    }
}

/**
 * Decode one JSON line from `opencode run --format json`.
 *
 * Assistant text arrives in small deltas carrying a stable part id; consecutive
 * deltas for the same part are coalesced into one transcript entry. Non-JSON
 * output is kept as a status line so CLI diagnostics remain visible.
 */
bool decodeAgentLine(string line, ref AgentMessage[] messages, ref string status)
{
    line = line.strip();
    if (!line.length) return false;

    try
    {
        auto event = parseJSON(line);
        immutable kind = jsonFieldText(event, "type");

        if (kind == "text" || kind == "reasoning")
        {
            auto part = jsonField(event, "part");
            immutable delta = jsonFieldText(part, "text");
            if (!delta.length) return true;
            immutable key = jsonFieldText(part, "id");
            if (messages.length && messages[$ - 1].role == AgentRole.assistant &&
                messages[$ - 1].key == key && key.length)
                messages[$ - 1].text ~= delta;
            else
                appendMessage(messages, AgentMessage(AgentRole.assistant, delta, key));
            status = "Agent working...";
            return true;
        }

        if (kind == "tool_use")
        {
            auto part = jsonField(event, "part");
            auto state = jsonField(part, "state");
            immutable name = jsonFieldText(state, "title");
            immutable tool = name.length ? name : jsonFieldText(part, "tool");
            immutable stateText = jsonFieldText(state, "status");
            auto detail = stateText == "error"
                ? jsonFieldText(state, "error") : jsonFieldText(state, "output");
            if (!detail.length) detail = jsonText(jsonField(state, "input"));
            auto text = "Tool " ~ (tool.length ? tool : "call");
            if (stateText.length) text ~= " (" ~ stateText ~ ")";
            if (detail.length) text ~= "\n" ~ truncate(detail, 1600);
            appendMessage(messages, AgentMessage(AgentRole.tool, text));
            status = "Agent working...";
            return true;
        }

        if (kind == "error")
        {
            auto error = jsonField(event, "error");
            auto text = jsonFieldText(error, "message");
            if (!text.length) text = jsonText(error);
            immutable type = jsonFieldText(error, "type");
            if (type.length && !text.startsWith(type)) text = type ~ ": " ~ text;
            appendMessage(messages, AgentMessage(AgentRole.error, text));
            status = "Agent error";
            return true;
        }

        if (kind == "step_start") status = "Agent working...";
        if (kind == "step_finish") status = "Agent finished; ready";
        if (kind == "background_wait") status = "Agent waiting for background tools";
        return true;
    }
    catch (Exception)
    {
        // Some CLI diagnostics are plain text even in --format json mode.
        appendMessage(messages, AgentMessage(AgentRole.status, line.strip()));
        return false;
    }
}

/// Live bridge owned by the GUI thread.
final class AgentBridge
{
    string sessionId;
    string projectRoot;
    string projectName;
    AgentMessage[] messages;
    bool busy;
    string status = "Agent ready";

    /// Incremented whenever the transcript changes, so the UI can auto-scroll.
    ulong revision;

    private Pid pid;
    private bool hasPid;
    private ulong generation;
    private bool dirty;
    private size_t changesSinceSave;
    private AgentChannel channel;

    this()
    {
        channel = new AgentChannel();
    }

    /// Write queued transcript changes to the app cache immediately.
    void persist()
    {
        flush();
    }

    /// Switch projects: persist the old transcript, then load the new one.
    void open(string root, string name)
    {
        if (projectRoot.length) flush();
        close();
        projectRoot = root;
        projectName = name;
        load();
        status = messages.length ? "Ready - continue the session"
                                 : "Ready - ask the agent";
        revision++;
    }

    /// Stop a running CLI process. Safe when nothing is running.
    void close()
    {
        generation++;
        if (hasPid)
        {
            try
                kill(pid);
            catch (Exception)
            {
                // Already exited; the reader thread will report completion.
            }
            hasPid = false;
        }
        busy = false;
    }

    /// Submit a prompt. The active file is attached with `opencode run --file`.
    bool send(string prompt, string activeFile)
    {
        prompt = prompt.strip();
        if (busy || !prompt.length || !projectRoot.length) return false;

        appendMessage(messages, AgentMessage(AgentRole.user, prompt));
        revision++;
        markDirty();

        if (!sessionId.length)
            sessionId = makeSessionId(projectRoot,
                                      cast(ulong) Clock.currTime().toUnixTime());

        string[] args = [
            "opencode", "--standalone", "run",
            "--session", sessionId,
            "--format", "json",
            "--auto",
            "--archived",
            "--title", "dcad - " ~ (projectName.length ? projectName : "project")
        ];
        if (activeFile.length)
            args ~= ["--file", activeFile];

        auto context = format("dcad project: %s\nProject root: %s\nActive file: %s\n\n%s",
            projectName.length ? projectName : "(unnamed)",
            projectRoot,
            activeFile.length ? activeFile : "(none)",
            prompt);
        args ~= context;

        // A private server honours OPENCODE_DB, keeping opencode's own session
        // database in dcad's app cache. Config/auth paths stay unchanged so the
        // user's existing credentials continue to work.
        auto childEnv = environment.toAA();
        mkdirRecurse(agentCacheDir());
        childEnv["OPENCODE_DB"] = buildPath(agentCacheDir(), "opencode.db");

        busy = true;
        status = "Agent starting...";
        immutable myGeneration = ++generation;
        try
        {
            auto pipes = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout,
                                     childEnv, Config.none, projectRoot);
            pid = pipes.pid;
            hasPid = true;
            auto state = new AgentWorkerState(
                pipes.stdout, pid, myGeneration, channel);
            auto worker = new Thread(&state.run);
            worker.isDaemon = true;
            worker.start();
        }
        catch (Exception e)
        {
            busy = false;
            hasPid = false;
            auto text = "Cannot start opencode: " ~ e.msg
                      ~ "\nInstall the opencode CLI and make sure it is on PATH.";
            appendMessage(messages, AgentMessage(AgentRole.error, text));
            status = "Agent unavailable";
            revision++;
            flush();
            return false;
        }
        return true;
    }

    /// Drain all messages queued by the reader thread. Call once per frame.
    void drain()
    {
        AgentPipeLine[] lines;
        AgentProcessDone[] results;
        channel.take(lines, results);

        foreach (msg; lines)
        {
            if (msg.generation != generation) continue;
            immutable before = messages.length;
            if (decodeAgentLine(msg.text, messages, status))
            {
                if (messages.length != before || status == "Agent working...")
                    revision++;
            }
            else
                revision++;
            markDirty();
        }

        foreach (msg; results)
        {
            if (msg.generation != generation) continue;
            busy = false;
            hasPid = false;
            if (msg.code == 0)
                status = "Agent ready";
            else
            {
                status = msg.code == -1
                    ? "Agent failed: " ~ (msg.error.length ? msg.error : "reader error")
                    : format("Agent exited with code %d", msg.code);
                appendMessage(messages, AgentMessage(AgentRole.status, status));
                revision++;
            }
            flush();
        }
    }

    private void markDirty()
    {
        dirty = true;
        if (++changesSinceSave >= 32) flush();
    }

    private void flush()
    {
        if (!dirty || !projectRoot.length) return;
        save();
        dirty = false;
        changesSinceSave = 0;
    }

    private void save()
    {
        mkdirRecurse(agentCacheDir());
        auto root = JSONValue.emptyObject;
        root["project"] = JSONValue(projectRoot);
        root["session"] = JSONValue(sessionId);

        auto entries = JSONValue.emptyArray;
        foreach (msg; messages)
        {
            auto entry = JSONValue.emptyObject;
            entry["role"] = JSONValue(roleName(msg.role));
            entry["text"] = JSONValue(msg.text);
            if (msg.key.length) entry["key"] = JSONValue(msg.key);
            entries.array ~= entry;
        }
        root["messages"] = entries;
        write(agentCachePath(projectRoot), root.toString());
    }

    private void load()
    {
        messages = null;
        sessionId = null;
        immutable path = agentCachePath(projectRoot);
        if (exists(path))
        {
            try
            {
                auto root = parseJSON(readText(path));
                sessionId = jsonFieldText(root, "session");
                auto entries = jsonField(root, "messages");
                if (entries.type == JSONType.array)
                    foreach (entry; entries.array)
                    {
                        auto text = jsonFieldText(entry, "text");
                        if (!text.length) continue;
                        appendMessage(messages,
                            AgentMessage(parseRole(jsonFieldText(entry, "role")),
                                         text, jsonFieldText(entry, "key")));
                    }
            }
            catch (Exception)
            {
                sessionId = null;
                messages = null;
            }
        }
        if (!sessionId.startsWith("ses"))
            sessionId = makeSessionId(projectRoot,
                                      cast(ulong) Clock.currTime().toUnixTime());
    }
}
