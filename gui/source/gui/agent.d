/**
 * Agent tab bridge.
 *
 * This module is now a compatibility façade: the legacy installed-CLI path is
 * still here for the transition, while the embedded Big Pickle port lives in
 * gui.agentcore.* modules. The replacement keeps all model/tool work off the GUI
 * thread and drains events once per frame.
 *
 * Project history is stored in <project>/.dcad/history.jsonl. Credentials stay
 * in dcad's app cache and are never written into a project.
 */
module gui.agent;

public import gui.agentcore.messages : AgentMessage, AgentRole;
public import gui.agentcore.events : AgentEvent, AgentEventType,
                                decodeAgentEvent, projectAgentEvent;
public import gui.agentcore.history : AgentHistoryEntry, appendAgentHistory,
                                readAgentHistory, writeAgentHistorySnapshot;
public import gui.agentcore.llm : AgentChatMessage, AgentCompletionChunk,
                                bigPickleModel, chatCompletionsURL,
                                isAgentStreamDone, makeChatRequest,
                                parseChatCompletionChunk;
public import gui.agentcore.credentials : AgentCredential, AgentCredentials,
                                defaultAgentBaseURL;
public import gui.agentcore.sse : AgentSSEEvent, AgentSSEParser;
public import gui.agentcore.paths : agentConfigDir, agentHistoryDir;
public import gui.agentcore.transport : AgentHTTPRequest, AgentHTTPResult,
                                AgentMemoryTransport, AgentTransport,
                                AgentUnavailableTransport;
public import gui.agentcore.permissions : AgentPermissionDecision,
                                AgentPermissionEffect, AgentPermissionReply,
                                AgentPermissionRequest, AgentPermissionRule,
                                AgentPermissions;
public import gui.agentcore.tools : AgentSubagentRunner, AgentTool,
                                AgentToolRegistry;
public import gui.agentcore.runner : AgentPermissionApprover,
                                AgentSessionRunner;
public import gui.agentcore.patches : AgentFileDiff, AgentPatchSet,
                                AgentPatchStore, revertEventData;
public import gui.agentcore.schema : AgentFinishReason, AgentModelRef,
                                AgentPromptInput, AgentSessionInfo,
                                AgentToolCall, AgentToolState,
                                normalizeFinishReason, parseAgentSessionInfo,
                                parseAgentPromptInput;

import gui.agentcore.paths : agentAppCacheDir, agentHistoryPath;
import gui.agentcore.credentials : AgentCredentials;
import gui.agentcore.permissions : AgentPermissions;
import gui.agentcore.runner : AgentSessionRunner;
import gui.agentcore.tools : AgentToolRegistry;
import gui.agentcore.transport : AgentTransport;
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

/// Events emitted by the embedded runner, tagged so stale work is discarded.
private struct AgentCoreEvent
{
    ulong generation;
    AgentEvent event;
}

private struct AgentCoreDone
{
    ulong generation;
    string error;
}

final class AgentCancelToken
{
    private Mutex mutex;
    private bool cancelled;

    this()
    {
        mutex = new Mutex();
    }

    void cancel()
    {
        synchronized (mutex) cancelled = true;
    }

    bool isCancelled()
    {
        synchronized (mutex) return cancelled;
    }
}

/// Thread-safe mailbox between workers and the GUI thread.
private final class AgentChannel
{
    private Mutex mutex;
    private AgentPipeLine[] lines;
    private AgentProcessDone[] results;
    private AgentCoreEvent[] coreEvents;
    private AgentCoreDone[] coreResults;

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

    void pushEvent(ulong generation, AgentEvent event)
    {
        synchronized (mutex)
            coreEvents ~= AgentCoreEvent(generation, event);
    }

    void pushCoreDone(ulong generation, string error)
    {
        synchronized (mutex)
            coreResults ~= AgentCoreDone(generation, error);
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

    void takeCore(ref AgentCoreEvent[] outEvents,
                  ref AgentCoreDone[] outResults)
    {
        synchronized (mutex)
        {
            outEvents = coreEvents;
            outResults = coreResults;
            coreEvents = null;
            coreResults = null;
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

/// Runs the embedded session core entirely off the GUI thread.
private final class AgentCoreWorkerState
{
    AgentSessionRunner runner;
    AgentTransport transport;
    AgentCredential credential;
    AgentPermissions permissions;
    string projectRoot;
    string prompt;
    string activeFile;
    ulong generation;
    AgentChannel channel;
    AgentCancelToken token;

    this(AgentSessionRunner runner, AgentTransport transport,
         AgentCredential credential, AgentPermissions permissions,
         string projectRoot, string prompt, string activeFile,
         ulong generation, AgentChannel channel, AgentCancelToken token)
    {
        this.runner = runner;
        this.transport = transport;
        this.credential = credential;
        this.permissions = permissions;
        this.projectRoot = projectRoot;
        this.prompt = prompt;
        this.activeFile = activeFile;
        this.generation = generation;
        this.channel = channel;
        this.token = token;
    }

    /// Child session used by the `subagent` tool. It cannot spawn further
    /// subagents and only forwards useful transcript events to the UI.
    string runSubagent(string task, string activeFile,
                       scope void delegate(AgentEvent) emit,
                       scope bool delegate() cancelled)
    {
        auto childID = makeSessionId(projectRoot,
            cast(ulong) Clock.currTime().toUnixTime() ^ fnv1a(task));
        auto childTools = new AgentToolRegistry();
        auto childRunner = new AgentSessionRunner(
            transport, childTools, permissions, credential,
            projectRoot, childID, 4, "subagent-" ~ childID);

        string answer;
        void collect(AgentEvent event)
        {
            final switch (event.type)
            {
                case AgentEventType.textDelta:
                    answer ~= event.delta;
                    channel.pushEvent(generation, event);
                    break;
                case AgentEventType.toolCalled:
                case AgentEventType.toolSuccess:
                case AgentEventType.toolFailed:
                    channel.pushEvent(generation, event);
                    break;
                case AgentEventType.serverConnected:
                case AgentEventType.executionStarted:
                case AgentEventType.executionSucceeded:
                case AgentEventType.executionFailed:
                case AgentEventType.executionInterrupted:
                case AgentEventType.stepStarted:
                case AgentEventType.stepFirstToken:
                case AgentEventType.stepStreamed:
                case AgentEventType.stepEnded:
                case AgentEventType.stepFailed:
                case AgentEventType.reasoningDelta:
                case AgentEventType.toolInputStarted:
                case AgentEventType.toolInputDelta:
                case AgentEventType.toolInputEnded:
                case AgentEventType.toolProgress:
                case AgentEventType.permissionAsked:
                case AgentEventType.permissionReplied:
                case AgentEventType.sessionIdle:
                case AgentEventType.revertStaged:
                case AgentEventType.revertCleared:
                case AgentEventType.revertCommitted:
                case AgentEventType.unknown:
                    break;
            }
        }
        childRunner.run(task, activeFile, &collect, cancelled,
                        delegate(AgentPermissionRequest) { return true; });
        return answer.length ? answer : "subagent completed without text";
    }

    void run()
    {
        try
        {
            runner.run(prompt, activeFile,
                delegate(AgentEvent event) {
                    channel.pushEvent(generation, event);
                },
                delegate() { return token.isCancelled(); },
                delegate(AgentPermissionRequest) { return true; });
            channel.pushCoreDone(generation, null);
        }
        catch (Exception e)
            channel.pushCoreDone(generation, e.msg);
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

/// App-cache location for credentials and transient agent state.
string agentCacheDir()
{
    return agentAppCacheDir();
}

/// Project-owned transcript location used by the embedded agent core.
string agentHistoryFilePath(string projectRoot)
{
    return agentHistoryPath(projectRoot);
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

    /// Set by dcad when the embedded core is selected. Null keeps the legacy
    /// installed-CLI bridge available during the transition.
    AgentTransport transport;

    private AgentCancelToken cancelToken;
    private string stagedPatchID;
    private bool editorRefreshRequested;

    this()
    {
        channel = new AgentChannel();
    }

    /// Select the in-process agent core. The transport is supplied by dcad so
    /// tests can inject a deterministic implementation.
    void useEmbedded(AgentTransport selected)
    {
        close();
        transport = selected;
    }

    /// Current dcad-owned credential. Environment overrides win over the
    /// persisted value, matching the agent core's loader.
    AgentCredential credential()
    {
        return (new AgentCredentials()).load();
    }

    /// Persist credentials in dcad's app cache, never in the open project.
    void saveCredential(string apiKey, string baseURL)
    {
        (new AgentCredentials()).save(AgentCredential(strip(apiKey), strip(baseURL)));
    }

    /// True when a model edit has an undoable project patch.
    bool hasPatch() const @property
    {
        return stagedPatchID.length != 0;
    }

    /// Unified diff for the staged change; empty when nothing is staged.
    string patchDiff()
    {
        if (!hasPatch || !projectRoot.length) return "";
        return (new AgentPatchStore(projectRoot)).patchText(stagedPatchID);
    }

    /// Project-relative files touched by the staged change.
    string[] patchFiles()
    {
        if (!hasPatch || !projectRoot.length) return null;
        auto set = (new AgentPatchStore(projectRoot)).load(stagedPatchID);
        string[] result;
        foreach (file; set.files) result ~= file.file;
        return result;
    }

    /// True once after a staged change touches the file open in the editor.
    bool consumeEditorRefresh()
    {
        immutable requested = editorRefreshRequested;
        editorRefreshRequested = false;
        return requested;
    }

    /// Restore project files to their state before the staged change.
    bool undoLastChange()
    {
        if (!hasPatch || !projectRoot.length || busy) return false;
        auto store = new AgentPatchStore(projectRoot);
        if (!store.undo(stagedPatchID)) return false;
        appendMessage(messages, AgentMessage(AgentRole.status, "Change undone",
                                             "undo:" ~ stagedPatchID));
        editorRefreshRequested = true;
        stagedPatchID = null;
        status = "Change undone";
        revision++;
        flush();
        return true;
    }

    /// Keep the staged edits and drop the undo snapshot.
    bool keepLastChange()
    {
        if (!hasPatch || !projectRoot.length || busy) return false;
        auto store = new AgentPatchStore(projectRoot);
        if (!store.clear(stagedPatchID)) return false;
        appendMessage(messages, AgentMessage(AgentRole.status, "Change kept",
                                             "keep:" ~ stagedPatchID));
        stagedPatchID = null;
        status = "Change kept";
        revision++;
        flush();
        return true;
    }

    /// Explicit Stop for the UI. Stale worker events are discarded by the
    /// generation guard in drain().
    void stop()
    {
        if (!busy) return;
        close();
        appendMessage(messages, AgentMessage(AgentRole.status, "Agent interrupted",
                                             "interrupt:ui"));
        status = "Agent stopped";
        revision++;
        flush();
    }

    private void refreshPatch()
    {
        stagedPatchID = null;
        if (!projectRoot.length) return;
        auto latest = (new AgentPatchStore(projectRoot)).latest();
        stagedPatchID = latest.id;
    }

    private static string patchIDFromEvent(AgentEvent event)
    {
        if (event.revert.type != JSONType.object) return "";
        if (auto value = "snapshot" in event.revert.object)
            if (value.type == JSONType.string) return value.str;
        if (auto value = "messageID" in event.revert.object)
            if (value.type == JSONType.string) return value.str;
        return "";
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
        refreshPatch();
        status = messages.length ? "Ready - continue the session"
                                 : "Ready - ask the agent";
        revision++;
    }

    /// Stop a running worker or CLI process. Safe when nothing is running.
    void close()
    {
        generation++;
        if (cancelToken !is null)
        {
            cancelToken.cancel();
            cancelToken = null;
        }
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

        if (transport !is null)
            return sendEmbedded(activeFile);

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

    private bool sendEmbedded(string activeFile)
    {
        auto credential = (new AgentCredentials()).load();
        if (!credential.hasKey)
        {
            appendMessage(messages, AgentMessage(AgentRole.error,
                "dcad agent API key is not configured. Add it in the Agent tab."));
            status = "Agent unavailable";
            revision++;
            flush();
            return false;
        }

        auto permissions = new AgentPermissions();
        cancelToken = new AgentCancelToken();
        busy = true;
        status = "Agent working...";
        immutable myGeneration = ++generation;

        auto state = new AgentCoreWorkerState(
            null, transport, credential, permissions, projectRoot,
            promptTextForRun(activeFile), activeFile,
            myGeneration, channel, cancelToken);
        auto tools = new AgentToolRegistry(
            delegate(string task, string childFile,
                     scope void delegate(AgentEvent) emit,
                     scope bool delegate() cancelled) {
                return state.runSubagent(task, childFile, emit, cancelled);
            });
        auto runner = new AgentSessionRunner(
            transport, tools, permissions, credential,
            projectRoot, sessionId);
        state.runner = runner;

        auto worker = new Thread(&state.run);
        worker.isDaemon = true;
        worker.start();
        return true;
    }

    /// Rebuild the user prompt for the runner. send() already appended the same
    /// text to the transcript, so this is only the worker's input payload.
    private string promptTextForRun(string activeFile)
    {
        if (!messages.length ||
            messages[$ - 1].role != AgentRole.user)
            return "";
        return messages[$ - 1].text;
    }

    /// Drain all messages queued by the reader thread. Call once per frame.
    void drain()
    {
        AgentPipeLine[] lines;
        AgentProcessDone[] results;
        AgentCoreEvent[] coreEvents;
        AgentCoreDone[] coreResults;
        channel.take(lines, results);
        channel.takeCore(coreEvents, coreResults);

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

        foreach (msg; coreEvents)
        {
            if (msg.generation != generation) continue;
            immutable before = messages.length;
            immutable previousStatus = status;
            if (projectAgentEvent(msg.event, messages, status))
            {
                if (messages.length != before || status != previousStatus)
                    revision++;
            }
            final switch (msg.event.type)
            {
                case AgentEventType.revertStaged:
                {
                    immutable previous = stagedPatchID;
                    stagedPatchID = patchIDFromEvent(msg.event);
                    if (stagedPatchID.length && stagedPatchID != previous)
                        editorRefreshRequested = true;
                    break;
                }
                case AgentEventType.revertCleared:
                case AgentEventType.revertCommitted:
                    stagedPatchID = null;
                    break;
                case AgentEventType.serverConnected:
                case AgentEventType.executionStarted:
                case AgentEventType.executionSucceeded:
                case AgentEventType.executionFailed:
                case AgentEventType.executionInterrupted:
                case AgentEventType.stepStarted:
                case AgentEventType.stepFirstToken:
                case AgentEventType.stepStreamed:
                case AgentEventType.stepEnded:
                case AgentEventType.stepFailed:
                case AgentEventType.textDelta:
                case AgentEventType.reasoningDelta:
                case AgentEventType.toolInputStarted:
                case AgentEventType.toolInputDelta:
                case AgentEventType.toolInputEnded:
                case AgentEventType.toolCalled:
                case AgentEventType.toolProgress:
                case AgentEventType.toolSuccess:
                case AgentEventType.toolFailed:
                case AgentEventType.permissionAsked:
                case AgentEventType.permissionReplied:
                case AgentEventType.sessionIdle:
                case AgentEventType.unknown:
                    break;
            }
            markDirty();
        }

        foreach (msg; coreResults)
        {
            if (msg.generation != generation) continue;
            busy = false;
            cancelToken = null;
            if (msg.error.length)
            {
                status = "Agent failed: " ~ msg.error;
                appendMessage(messages, AgentMessage(AgentRole.error, status));
                revision++;
            }
            else
                status = "Agent ready";
            flush();
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

        // The project-owned history file is the source of truth going forward.
        // Mirror the legacy bridge's transcript until the embedded runner
        // replaces this save path.
        try
            writeAgentHistorySnapshot(projectRoot, sessionId, messages);
        catch (Exception)
        {
            // A history write failure must not lose the app-cache transcript.
        }
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
