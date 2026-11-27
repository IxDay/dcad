/**
 * Fixed D language-server bridge.
 *
 * dcad talks only to `serve-d` over stdio. The executable is resolved from
 * DCAD_LSP_EXECUTABLE, the application resource directory, then PATH. There is
 * no server discovery, plugin configuration or MCP configuration. Missing
 * serve-d is reported in the UI and the editor keeps its existing compiler
 * diagnostics.
 */
module gui.lsp.bridge;

import core.sync.mutex : Mutex;
import core.thread.osthread : Thread;
import core.time : dur;

import std.algorithm : startsWith;
import std.conv : to;
import std.file : exists;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.process : Config, Pid, Redirect, environment,
                    kill, pipeProcess, wait;
import std.stdio : File;
import std.string : indexOf, split, strip, toLower;

import gui.agentcore.schema : agentField, agentStringField, agentUnsignedField;
import gui.lsp.protocol;
import gui.platform : resourceRoot;

/// Minimal transport seam. The stdio implementation owns serve-d; the memory
/// implementation is deterministic for headless tests.
interface LspChannel
{
    void send(string message);
    bool receive(ref string message);
    /// Stop the source without releasing a handle another thread may be
    /// blocked on. The bridge joins its reader before calling dispose().
    void interrupt();
    void dispose();
    void close();
}

final class LspMemoryChannel : LspChannel
{
    private Mutex mutex;
    private string[] incoming;
    private string[] outgoing;

    this()
    {
        mutex = new Mutex();
    }

    void push(string message)
    {
        synchronized (mutex) incoming ~= message;
    }

    string[] sent()
    {
        synchronized (mutex) return outgoing.dup;
    }

    void send(string message)
    {
        synchronized (mutex) outgoing ~= message;
    }

    bool receive(ref string message)
    {
        synchronized (mutex)
        {
            if (!incoming.length) return false;
            message = incoming[0];
            incoming = incoming[1 .. $];
            return true;
        }
    }

    void interrupt()
    {
        synchronized (mutex) incoming = null;
    }

    void dispose()
    {
    }

    void close()
    {
        interrupt();
    }
}

final class LspStdioChannel : LspChannel
{
    private Mutex mutex;
    private Pid pid;
    private File stdinFile;
    private File stdoutFile;
    private bool closed;

    this(Pid pid, File stdinFile, File stdoutFile)
    {
        mutex = new Mutex();
        this.pid = pid;
        this.stdinFile = stdinFile;
        this.stdoutFile = stdoutFile;
    }

    void send(string message)
    {
        synchronized (mutex)
        {
            if (closed) return;
            try
            {
                stdinFile.rawWrite(message);
                stdinFile.flush();
            }
            catch (Exception)
                closed = true;
        }
    }

    bool receive(ref string message)
    {
        char[] line;
        ulong length;
        while (true)
        {
            synchronized (mutex)
            {
                if (closed) return false;
            }
            try
            {
                if (stdoutFile.readln(line) == 0) return false;
            }
            catch (Exception)
                return false;

            auto header = strip(line);
            if (!header.length) break;

            immutable colon = indexOf(header, ':');
            if (colon < 0 || toLower(strip(header[0 .. colon])) != "content-length")
                continue;
            try length = strip(header[colon + 1 .. $]).to!ulong;
            catch (Exception) return false;
        }

        if (!length || length > 32 * 1024 * 1024) return false;
        try
        {
            auto body = stdoutFile.rawRead(new ubyte[cast(size_t) length]);
            if (body.length != length) return false;
            message = cast(string) body.idup;
            return true;
        }
        catch (Exception)
            return false;
    }

    void interrupt()
    {
        synchronized (mutex)
        {
            if (closed) return;
            closed = true;
            try kill(pid); catch (Exception) { /* already exited */ }
            try wait(pid); catch (Exception) { /* already reaped */ }
            try stdinFile.close(); catch (Exception) { /* already closed */ }
        }
    }

    void dispose()
    {
        synchronized (mutex)
        {
            try stdoutFile.close(); catch (Exception) { /* already closed */ }
        }
    }

    void close()
    {
        interrupt();
        dispose();
    }
}

struct LspSnapshot
{
    bool running;
    string status;
    LspDiagnostic[] diagnostics;
    LspCompletionItem[] completions;
}

private string searchPath(string name)
{
    version (Windows) enum separator = ";";
    else enum separator = ":";

    auto directories = split(environment.get("PATH", ""), separator);
    foreach (directory; directories)
    {
        if (!directory.length) continue;
        auto candidate = buildPath(directory, name);
        if (exists(candidate)) return candidate;
    }
    return null;
}

private string resolveServeD()
{
    auto configured = environment.get("DCAD_LSP_EXECUTABLE", "");
    if (configured.length)
    {
        if (exists(configured)) return configured;
        return searchPath(configured);
    }

    version (Windows) enum executable = "serve-d.exe";
    else enum executable = "serve-d";

    auto bundled = buildPath(resourceRoot(), executable);
    if (exists(bundled)) return bundled;
    return searchPath(executable);
}

/// Shared state owned by the GUI thread and the reader worker.
private final class LspBridgeState
{
    Mutex mutex;
    LspChannel channel;
    string projectRoot;
    ulong epoch;
    bool running;
    string status = "D language server not started";
    long nextID = 1;
    long initializeID;
    long completionID;
    long[string] versions;
    LspDiagnostic[] diagnostics;
    LspCompletionItem[] completions;

    this()
    {
        mutex = new Mutex();
    }

    bool isCurrent(ulong candidate)
    {
        synchronized (mutex) return epoch == candidate && running;
    }

    void markStopped(ulong candidate, string reason)
    {
        synchronized (mutex)
        {
            if (epoch != candidate) return;
            running = false;
            status = reason;
        }
    }

    void process(ulong candidate, JSONValue message)
    {
        synchronized (mutex)
        {
            if (epoch != candidate || !running || channel is null) return;

            auto method = agentStringField(message, "method");
            auto id = cast(long) agentUnsignedField(message, "id");
            auto result = agentField(message, "result");
            auto error = agentField(message, "error");

            if (method == "textDocument/publishDiagnostics")
            {
                diagnostics = parseLspDiagnostics(message);
                status = "serve-d: " ~ diagnostics.length.to!string
                       ~ " diagnostic(s)";
                return;
            }

            // Server-initiated requests must get a reply or serve-d stalls.
            if (method.length && id)
            {
                JSONValue reply;
                bool replyReady;
                if (method == "workspace/configuration")
                {
                    JSONValue[] values = [JSONValue.emptyObject];
                    reply = lspResponse(id, JSONValue(values));
                    replyReady = true;
                }
                else if (method == "client/registerCapability")
                {
                    reply = lspResponse(id, JSONValue.init);
                    replyReady = true;
                }
                if (replyReady) channel.send(encodeLspMessage(reply));
                return;
            }

            if (id && id == initializeID && result.type != JSONType.null_)
            {
                channel.send(encodeLspMessage(lspInitialized()));
                status = "serve-d ready";
                return;
            }

            if (id && id == completionID)
            {
                if (error.type != JSONType.null_)
                {
                    completions = null;
                    status = "serve-d completion failed";
                }
                else
                {
                    completions = parseLspCompletions(message);
                    status = completions.length
                        ? "serve-d: completion available"
                        : "serve-d: no completions";
                }
                completionID = 0;
            }
        }
    }
}

/// Reads serve-d stdout on its own thread. All GUI-owned state is copied into
/// LspBridgeState, never touched directly by the worker.
private final class LspReaderState
{
    LspBridgeState state;
    LspChannel channel;
    ulong epoch;

    this(LspBridgeState state, LspChannel channel, ulong epoch)
    {
        this.state = state;
        this.channel = channel;
        this.epoch = epoch;
    }

    void run()
    {
        while (state.isCurrent(epoch))
        {
            string message;
            bool received;
            try received = channel.receive(message);
            catch (Exception)
            {
                state.markStopped(epoch, "serve-d reader failed");
                return;
            }
            if (!received)
            {
                Thread.sleep(dur!"msecs"(5));
                if (!state.isCurrent(epoch)) return;
                if (cast(LspStdioChannel) channel !is null)
                {
                    state.markStopped(epoch, "serve-d exited");
                    return;
                }
                continue;
            }
            JSONValue decoded;
            try decoded = parseJSON(message);
            catch (Exception) continue;
            state.process(epoch, decoded);
        }
    }
}

final class DLspBridge
{
    private LspBridgeState state;
    private Thread reader;
    private LspChannel injectedChannel;

    /// Inject a channel for tests. Production uses the fixed stdio bridge.
    this(LspChannel injected = null)
    {
        state = new LspBridgeState();
        injectedChannel = injected;
    }

    /// Fail-soft start. Returns false when serve-d is not available.
    bool start(string projectRoot)
    {
        bool wasRunning;
        synchronized (state.mutex) wasRunning = state.running;
        if (wasRunning) shutdown();

        auto channel = injectedChannel;
        if (channel !is null)
            injectedChannel = null;
        else
        {
            auto executable = resolveServeD();
            if (!executable.length)
            {
                synchronized (state.mutex)
                    state.status = "serve-d not found - compiler diagnostics only";
                return false;
            }

            auto args = [executable];
            try
            {
                auto pipes = pipeProcess(args,
                    Redirect.stdout | Redirect.stdin,
                    environment.toAA(), Config.none, absolutePath(projectRoot));
                channel = new LspStdioChannel(pipes.pid, pipes.stdin, pipes.stdout);
            }
            catch (Exception e)
            {
                synchronized (state.mutex)
                    state.status = "serve-d failed to start: " ~ e.msg;
                return false;
            }
        }

        ulong epoch;
        synchronized (state.mutex)
        {
            state.channel = channel;
            state.projectRoot = absolutePath(projectRoot);
            state.diagnostics = null;
            state.completions = null;
            state.versions = null;
            ++state.epoch;
            epoch = state.epoch;
            state.running = true;
            state.status = "serve-d starting";
            state.initializeID = state.nextID++;
            channel.send(encodeLspMessage(
                lspInitialize(state.initializeID,
                              lspPathToURI(state.projectRoot))));
        }

        auto workerState = new LspReaderState(state, channel, epoch);
        reader = new Thread(&workerState.run);
        reader.isDaemon = true;
        reader.start();
        return true;
    }

    private string documentURI(string path)
    {
        synchronized (state.mutex)
        {
            if (!state.projectRoot.length) return lspPathToURI(absolutePath(path));
            return lspPathToURI(absolutePath(buildPath(state.projectRoot, path)));
        }
    }

    private long bumpVersion(string uri)
    {
        synchronized (state.mutex)
        {
            auto found = uri in state.versions;
            if (found !is null) return ++(*found);
            state.versions[uri] = 1;
            return 1;
        }
    }

    private void sendMessage(JSONValue message)
    {
        synchronized (state.mutex)
        {
            if (state.channel !is null && state.running)
                state.channel.send(encodeLspMessage(message));
        }
    }

    void openDocument(string path, string text)
    {
        auto uri = documentURI(path);
        sendMessage(lspDidOpen(uri, text, bumpVersion(uri)));
    }

    void changeDocument(string path, string text)
    {
        auto uri = documentURI(path);
        sendMessage(lspDidChange(uri, text, bumpVersion(uri)));
    }

    void saveDocument(string path, string text)
    {
        sendMessage(lspDidSave(documentURI(path), text));
    }

    void closeDocument(string path)
    {
        sendMessage(lspDidClose(documentURI(path)));
    }

    void requestCompletion(string path, long line, long character)
    {
        long id;
        synchronized (state.mutex)
        {
            if (!state.running || state.channel is null) return;
            id = state.nextID++;
            state.completionID = id;
            state.completions = null;
            state.status = "serve-d: completion requested";
        }
        sendMessage(lspCompletion(id, documentURI(path),
                                  LspPosition(line, character)));
    }

    /// Copy worker-produced state onto the GUI thread.
    void drain(ref LspSnapshot destination)
    {
        synchronized (state.mutex)
        {
            destination.running = state.running;
            destination.status = state.status;
            destination.diagnostics = state.diagnostics.dup;
            destination.completions = state.completions.dup;
        }
    }

    void shutdown()
    {
        LspChannel channel;
        Thread worker;
        synchronized (state.mutex)
        {
            ++state.epoch;
            state.running = false;
            channel = state.channel;
            state.channel = null;
            state.status = "D language server stopped";
            worker = reader;
            reader = null;
        }
        // Stop the process and unblock the reader before touching the stdout
        // handle, then join so no worker outlives the bridge.
        if (channel !is null) channel.interrupt();
        if (worker !is null) worker.join();
        if (channel !is null) channel.dispose();
    }
}
