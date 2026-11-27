/**
 * Smoke test for the GUI script host's two source forms.
 *
 * Runs a legacy body-style script, a single element module directly, and a
 * module-style assembly with animation hooks, then checks the part count.
 */
module script_host_smoke;

import std.stdio : writeln, stderr;
import core.thread.osthread : Thread;
import core.time : dur;
import std.algorithm : startsWith;
import std.algorithm.searching : canFind;
import std.file : append, exists, readText, mkdirRecurse, tempDir, getcwd,
                  chdir, copy, write;
import std.path : baseName, buildPath;
import std.process : environment;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import gui.agent : AgentBridge, AgentChatMessage, AgentEvent, AgentEventType,
                   AgentHistoryEntry, AgentMemoryTransport, AgentMessage,
                   AgentPatchStore, AgentPermissionEffect, AgentPermissions,
                   AgentPermissionRequest, AgentPermissionRule, AgentRole,
                   AgentSessionRunner, AgentToolRegistry, agentCacheDir,
                   agentHistoryFilePath, appendAgentHistory, bigPickleModel,
                   chatCompletionsURL, decodeAgentLine, decodeAgentEvent,
                   isAgentStreamDone, makeChatRequest, parseChatCompletionChunk,
                   projectAgentEvent, makeSessionId, readAgentHistory,
                   writeAgentHistorySnapshot;
import gui.agentcore.credentials : AgentCredential, AgentCredentials,
                              defaultAgentBaseURL;
import gui.agentcore.patches : AgentChangeRecorder, revertEventData;
import gui.agentcore.schema : AgentFinishReason, agentBoolField,
                          finishReasonName, normalizeFinishReason,
                          parseAgentPromptInput, parseAgentSessionInfo;
import gui.agent_commands : agentCommandArgs, agentCommandHelp,
                            parseAgentCommand;
import gui.agentcore.sse : AgentSSEEvent, AgentSSEParser;
import gui.imgui : dcad_gui_font_selftest;
import gui.lsp.bridge : DLspBridge, LspMemoryChannel, LspSnapshot;
import gui.lsp.protocol : LspFrameReader, encodeLspMessage,
                          lspNotification, lspPathToURI, lspResponse,
                          parseLspCompletions, parseLspDiagnostics;
import gui.platform : processId, resourceRoot, sharedLibraryExtension;
import gui.project : Project;
import gui.script_host : ScriptHost;

int main(string[] args)
{
    // Release CI points this at the extracted launcher payload, so the same
    // script tests run against the private toolchain shipped to users.
    immutable overrideRoot = environment.get("DCAD_SCRIPT_HOST_ROOT", "");
    immutable root = overrideRoot.length ? overrideRoot : resourceRoot();

    // Build-time mode: compile a project's plugin and copy it, with its source
    // key, into build/ so the payload can load it without invoking ldc2 on
    // startup. This uses the same ScriptHost path as an ordinary Run.
    if (args.length >= 4 && args[1] == "--emit-plugin")
    {
        immutable outputBase = args[2];
        immutable projectDir = args[3];
        immutable entry = args.length > 4 ? args[4] : "main.d";
        immutable source = readText(buildPath(projectDir, entry));
        immutable emitWork = buildPath(tempDir(), "dcad-plugin-emit-"
                                       ~ processId.to!string ~ "-"
                                       ~ baseName(outputBase));
        mkdirRecurse(emitWork);
        auto emitHost = new ScriptHost(emitWork, root, projectDir);
        auto emitted = emitHost.run(source);
        if (!emitted.ok())
        {
            stderr.writeln("plugin emission failed: ", emitted.error);
            return 1;
        }
        immutable loaded = emitHost.loadedPath();
        if (!loaded.length || !exists(loaded))
        {
            stderr.writeln("plugin emission lost its loaded image");
            return 1;
        }
        copy(loaded, outputBase ~ sharedLibraryExtension());
        write(outputBase ~ ".key", emitHost.sourceCacheKey(source) ~ "\n");
        writeln("PASS: emitted ", outputBase);
        return 0;
    }

    // Force the no-bundled-font fallback at a scaled size and run ImGui's
    // frame-2 checks; this used to assert at startup on Windows high-DPI.
    // Run from an empty directory so the shim cannot find the checkout's
    // gui/assets through its relative fallback candidates.
    immutable fontWorkDir = buildPath(tempDir(), "dcad-font-selftest-"
                                      ~ processId.to!string);
    mkdirRecurse(fontWorkDir);
    immutable savedCwd = getcwd();
    chdir(fontWorkDir);
    immutable fontOk = dcad_gui_font_selftest() == 1;
    chdir(savedCwd);
    if (!fontOk)
    {
        stderr.writeln("ImGui fallback font self-test failed");
        return 1;
    }

    immutable workDir = buildPath(tempDir(), "dcad-script-host-smoke-"
                                  ~ processId.to!string);
    mkdirRecurse(workDir);

    // The coffee table is a real project, but never an implicit default. The
    // first-run modal can open it by selecting samples/coffee-table.
    auto sample = Project.open(buildPath(root, "samples", "coffee-table"));
    if (baseName(sample.root) != "coffee-table" ||
        sample.entry != "table.d" || !exists(sample.entryPath()) ||
        !exists(buildPath(sample.root, ".dcad.toml")))
    {
        stderr.writeln("coffee-table sample is not a valid dcad project");
        return 1;
    }

    immutable beforeLaunchDir = getcwd();
    chdir(sample.root);
    auto launchedHere = Project.open(".");
    chdir(beforeLaunchDir);
    if (baseName(launchedHere.root) != "coffee-table" ||
        launchedHere.entry != "table.d")
    {
        stderr.writeln("launch-directory project detection failed");
        return 1;
    }

    auto host = new ScriptHost(workDir, root);

    // Acceptance mode used after launcher extraction: prove startup can load
    // the shipped plugin instead of invoking the bundled compiler again.
    if (environment.get("DCAD_CHECK_PRECOMPILED", "") == "1")
    {
        auto shipped = host.runPrecompiled(
            readText(buildPath(root, "samples", "coffee-table", "table.d")),
            "dcad-coffee-table");
        if (!shipped.ok())
        {
            stderr.writeln("precompiled coffee-table failed: ", shipped.error);
            return 1;
        }
        immutable expected = "dcad-coffee-table" ~ sharedLibraryExtension();
        if (baseName(host.loadedPath()) != expected)
        {
            stderr.writeln("startup recompiled instead of loading ", expected,
                           ": ", host.loadedPath());
            return 1;
        }
    }

    // Legacy body-style script: the source is injected into dcad_script_run.
    auto body = host.run("Shape result = Workplane.create().box(2, 2, 2).shape;");
    if (!body.ok())
    {
        stderr.writeln("body form failed: ", body.error);
        return 1;
    }

    // One element module, opened and run directly from the project tree.
    auto element = host.run(readText(buildPath(root, "samples/coffee-table/leg.d")));
    if (!element.ok())
    {
        stderr.writeln("element module failed: ", element.error);
        return 1;
    }

    // Module-style assembly with animation hooks imported from other files.
    auto assembly = host.run(readText(buildPath(root, "gui/scripts/module-assembly.d")));
    if (!assembly.ok())
    {
        stderr.writeln("module form failed: ", assembly.error);
        return 1;
    }
    if (host.animPartCount() != 18)
    {
        stderr.writeln("module animation parts: ", host.animPartCount(),
                       " (expected 18)");
        return 1;
    }

    // File > New Project uses the same template; check it compiles and
    // exposes the three joints expected by the parts overlay.
    immutable projectDir = buildPath(workDir, "daimochi-tsugi");
    auto project = Project.create(projectDir, root);
    foreach (name; [".dcad.toml", "README.md", "main.d", "dimensions.d",
                    "daimochi_util.d", "part_a.d", "part_b.d", "key.d",
                    "motion.d"])
        if (!exists(buildPath(project.root, name)))
        {
            stderr.writeln("new project missing ", name);
            return 1;
        }

    // The TOML marker is the project root: opening the directory, the marker
    // itself, or a source file must all resolve to the same name and entry.
    foreach (candidate; [project.root,
                         buildPath(project.root, ".dcad.toml"),
                         project.entryPath])
    {
        auto opened = Project.open(candidate);
        if (opened.name != "Daimochi-tsugi" || opened.entry != "main.d")
        {
            stderr.writeln("project marker failed for ", candidate, ": ",
                           opened.name, " / ", opened.entry);
            return 1;
        }
    }

    // A distinct scratch dir avoids reusing a dylib path from the first host:
    // dlopen can hand back the old image if its dlclose was not final.
    immutable projectWorkDir = buildPath(tempDir(), "dcad-project-smoke-"
                                          ~ processId.to!string);
    mkdirRecurse(projectWorkDir);
    auto projectHost = new ScriptHost(projectWorkDir, root, project.root);
    auto joint = projectHost.run(readText(project.entryPath));
    if (!joint.ok())
    {
        stderr.writeln("new project failed: ", joint.error);
        return 1;
    }
    if (projectHost.animPartCount() != 3)
    {
        stderr.writeln("new project parts: ", projectHost.animPartCount(),
                       " (expected 3)");
        return 1;
    }

    // The Agent pane is keyboard-first: plain text goes to the model, while
    // slash commands drive every UI action that used to be a button.
    auto plainPrompt = parseAgentCommand("hello /commands");
    auto commandsPrompt = parseAgentCommand("  /Commands  ");
    auto authPrompt = parseAgentCommand(
        "/auth test-key http://127.0.0.1:1/v1");
    auto authArgs = agentCommandArgs(authPrompt.args);
    auto help = agentCommandHelp();
    if (plainPrompt.valid ||
        !commandsPrompt.valid || commandsPrompt.name != "commands" ||
        !authPrompt.valid || authPrompt.name != "auth" ||
        authArgs.length != 2 || authArgs[0] != "test-key" ||
        authArgs[1] != "http://127.0.0.1:1/v1" ||
        !help.canFind("/stop") || !help.canFind("/diff") ||
        !help.canFind("/keep") || !help.canFind("/undo") ||
        !help.canFind("/auth") || !help.canFind("/status"))
    {
        stderr.writeln("agent slash command parsing failed");
        return 1;
    }

    // Agent tab: the legacy CLI decoder is retained for the transition, while
    // the embedded core uses canonical V2 events and project-owned history.
    AgentMessage[] transcript;
    string agentStatus = "idle";
    decodeAgentLine(`{"type":"text","part":{"id":"p1","text":"Hello "}}`,
                    transcript, agentStatus);
    decodeAgentLine(`{"type":"text","part":{"id":"p1","text":"world"}}`,
                    transcript, agentStatus);
    if (transcript.length != 1 ||
        transcript[0].role != AgentRole.assistant ||
        transcript[0].text != "Hello world")
    {
        stderr.writeln("agent text deltas were not coalesced");
        return 1;
    }
    decodeAgentLine(`{"type":"tool_use","part":{"tool":"read","state":` ~
                    `{"status":"completed","title":"Read file","output":"ok"}}}`,
                    transcript, agentStatus);
    if (transcript.length != 2 || transcript[1].role != AgentRole.tool ||
        transcript[1].text != "Tool Read file (completed)\nok")
    {
        stderr.writeln("agent tool event was not displayed");
        return 1;
    }
    decodeAgentLine(`{"type":"error","error":{"type":"provider.free-limit",` ~
                    `"message":"limit reached"}}`, transcript, agentStatus);
    if (transcript.length != 3 || transcript[2].role != AgentRole.error ||
        agentStatus != "Agent error")
    {
        stderr.writeln("agent error event was not displayed");
        return 1;
    }

    // Canonical V2 event names are the embedded core's contract.
    AgentMessage[] canonical;
    string canonicalStatus = "idle";
    auto first = decodeAgentEvent(`{"event":"session.text.delta","data":` ~
        `{"sessionID":"ses1","assistantMessageID":"a1","ordinal":0,` ~
        `"delta":"Embedded "}}`);
    auto second = decodeAgentEvent(`{"event":"session.text.delta","data":` ~
        `{"sessionID":"ses1","assistantMessageID":"a1","ordinal":1,` ~
        `"delta":"agent"}}`);
    auto called = decodeAgentEvent(`{"event":"session.tool.called","data":` ~
        `{"id":"c1","name":"read","status":"running","input":{"file":"main.d"}}}`);
    if (first.type != AgentEventType.textDelta ||
        second.type != AgentEventType.textDelta ||
        called.type != AgentEventType.toolCalled ||
        !projectAgentEvent(first, canonical, canonicalStatus) ||
        !projectAgentEvent(second, canonical, canonicalStatus) ||
        !projectAgentEvent(called, canonical, canonicalStatus))
    {
        stderr.writeln("canonical V2 events were not decoded");
        return 1;
    }
    auto failed = decodeAgentEvent(`{"event":"session.execution.failed",` ~
        `"data":{"sessionID":"ses1","error":{"message":"limit reached"}}}`);
    if (!projectAgentEvent(failed, canonical, canonicalStatus) ||
        canonical.length != 3 ||
        canonical[0].text != "Embedded agent" ||
        canonical[0].key != "a1" ||
        canonical[1].role != AgentRole.tool ||
        canonical[1].text != "Tool read (running)" ||
        canonical[2].role != AgentRole.error ||
        canonicalStatus != "Agent error")
    {
        stderr.writeln("canonical event projection failed");
        return 1;
    }

    // Schema fields and finish reasons keep upstream names.
    auto info = parseAgentSessionInfo(parseJSON(
        `{"id":"ses1","parentID":"ses0","model":{"id":"big-pickle",` ~
        `"providerID":"opencode"},"tokens":{"input":7,"output":3,` ~
        `"cache":{"read":2,"write":1}},"location":{"directory":"/p"}}`));
    auto prompt = parseAgentPromptInput(parseJSON(
        `{"id":"m1","text":"hi","delivery":"queue","resume":false}`));
    if (info.parentID != "ses0" || info.model.id != "big-pickle" ||
        info.tokens.input != 7 || info.tokens.cacheRead != 2 ||
        info.directory != "/p" || prompt.resume ||
        prompt.delivery != "queue" ||
        normalizeFinishReason("tool_calls") != AgentFinishReason.toolCalls ||
        finishReasonName(AgentFinishReason.toolCalls) != "tool-calls")
    {
        stderr.writeln("agent schema projection failed");
        return 1;
    }

    // Big Pickle requests and streamed chat-completion chunks keep the
    // OpenAI-compatible wire shape normalized by the pinned upstream source.
    auto request = makeChatRequest(bigPickleModel,
                                   [AgentChatMessage("user", "hello")]);
    auto chunk = parseChatCompletionChunk(
        `{"id":"c1","model":"opencode/big-pickle","choices":[{"index":0,` ~
        `"delta":{"content":"Hi","tool_calls":[{"index":0,"id":"call_1",` ~
        `"type":"function","function":{"name":"read",` ~
        `"arguments":"{\"file\":"}}]},"finish_reason":"tool_calls"}],` ~
        `"usage":{"input":10,"output":2,"cache":{"read":1,"write":0}}}`);
    if (chatCompletionsURL("https://example.test/v1/") !=
            "https://example.test/v1/chat/completions" ||
        request.object["model"].str != bigPickleModel ||
        request.object["stream"].type != JSONType.true_ ||
        chunk.deltaText != "Hi" ||
        chunk.finishReason != AgentFinishReason.toolCalls ||
        chunk.toolCalls.length != 1 ||
        chunk.toolCalls[0].id != "call_1" ||
        chunk.toolCalls[0].name != "read" ||
        chunk.toolCalls[0].arguments != `{"file":` ||
        chunk.usage.input != 10 || !isAgentStreamDone("[DONE]"))
    {
        stderr.writeln("Big Pickle chat protocol failed");
        return 1;
    }

    // Permission rules keep upstream last-match-wins and multi-resource
    // precedence, and saved approvals cannot override a configured deny.
    auto permissions = new AgentPermissions();
    if (!permissions.decide("read", ["config.env"]).needsAsk() ||
        !permissions.decide("read", ["config.env.example"]).allowed())
    {
        stderr.writeln("base permission rules are wrong");
        return 1;
    }
    permissions.addRule(AgentPermissionRule(
        "shell", "*", AgentPermissionEffect.deny));
    permissions.addSavedAllow(AgentPermissionRule(
        "shell", "*", AgentPermissionEffect.allow));
    if (!permissions.decide("shell", ["pwd"]).denied())
    {
        stderr.writeln("saved permission overrode configured deny");
        return 1;
    }

    // File tools stay inside the project root and support the first edit path.
    string toolText(JSONValue result)
    {
        return result.object["content"].array[0].object["text"].str;
    }

    immutable toolProject = buildPath(workDir, "tool-project");
    mkdirRecurse(toolProject);
    auto tools = new AgentToolRegistry();
    JSONValue[string] writeInput;
    writeInput["file"] = JSONValue("note.txt");
    writeInput["content"] = JSONValue("alpha beta");
    auto wrote = tools.execute("write", JSONValue(writeInput), toolProject, null);

    JSONValue[string] readInput;
    readInput["file"] = JSONValue("note.txt");
    auto readBack = tools.execute("read", JSONValue(readInput), toolProject, null);

    JSONValue[string] editInput;
    editInput["file"] = JSONValue("note.txt");
    editInput["oldString"] = JSONValue("beta");
    editInput["newString"] = JSONValue("gamma");
    auto edited = tools.execute("edit", JSONValue(editInput), toolProject, null);

    JSONValue[string] globInput;
    globInput["pattern"] = JSONValue("*.txt");
    auto globbed = tools.execute("glob", JSONValue(globInput), toolProject, null);

    JSONValue[string] grepInput;
    grepInput["pattern"] = JSONValue("gamma");
    auto grepped = tools.execute("grep", JSONValue(grepInput), toolProject, null);

    JSONValue[string] escapeInput;
    escapeInput["file"] = JSONValue("../outside.txt");
    auto escaped = tools.execute("read", JSONValue(escapeInput), toolProject, null);

    if (agentBoolField(wrote, "isError") ||
        toolText(readBack) != "alpha beta" ||
        agentBoolField(edited, "isError") ||
        !toolText(globbed).canFind("note.txt") ||
        !toolText(grepped).canFind("note.txt:1:alpha gamma") ||
        !agentBoolField(escaped, "isError"))
    {
        stderr.writeln("embedded project tools failed");
        return 1;
    }

    // The runner streams a tool call, executes it, then continues to a final
    // answer. Everything is driven by a deterministic in-memory transport.
    string ssePayload(string payload)
    {
        return "data: " ~ payload ~ "\n\ndata: [DONE]\n\n";
    }

    auto toolResponse = ssePayload(
        `{"id":"c1","model":"opencode/big-pickle","choices":[{"index":0,` ~
        `"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function",` ~
        `"function":{"name":"write","arguments":` ~
        `"{\"file\":\"agent-note.txt\",\"content\":\"hello embedded\"}"}}]},` ~
        `"finish_reason":"tool_calls"}]}`);
    auto finalResponse = ssePayload(
        `{"id":"c2","model":"opencode/big-pickle","choices":[{"index":0,` ~
        `"delta":{"content":"Done"},"finish_reason":"stop"}]}`);
    auto transport = new AgentMemoryTransport([toolResponse, finalResponse]);
    auto runner = new AgentSessionRunner(
        transport, tools, new AgentPermissions(),
        AgentCredential("test-key", "http://127.0.0.1:1/v1"),
        toolProject, "ses-runner");

    AgentEvent[] events;
    void collect(AgentEvent event) { events ~= event; }
    bool neverCancel() { return false; }
    bool approve(AgentPermissionRequest) { return true; }
    runner.run("write a note", "main.d", &collect, &neverCancel, &approve);

    size_t toolSuccesses;
    size_t finalDeltas;
    bool sawIdle;
    foreach (event; events)
    {
        if (event.name == "session.tool.success") ++toolSuccesses;
        if (event.name == "session.text.delta" && event.delta == "Done")
            ++finalDeltas;
        if (event.name == "session.idle") sawIdle = true;
    }
    if (transport.calls != 2 ||
        transport.lastRequest.url != "http://127.0.0.1:1/v1/chat/completions" ||
        transport.lastHeaders["Authorization"] != "Bearer test-key" ||
        toolSuccesses != 1 || finalDeltas != 1 || !sawIdle ||
        !exists(buildPath(toolProject, "agent-note.txt")) ||
        readText(buildPath(toolProject, "agent-note.txt")) != "hello embedded")
    {
        stderr.writeln("embedded session runner failed");
        return 1;
    }

    // The `subagent` tool runs a bounded child session and returns its answer.
    auto childAnswer = ssePayload(
        `{"id":"child","model":"opencode/big-pickle","choices":[{"index":0,` ~
        `"delta":{"content":"child answer"},"finish_reason":"stop"}]}`);
    string runChild(string task, string childFile,
                    scope void delegate(AgentEvent) emit,
                    scope bool delegate() cancelled)
    {
        auto childTransport = new AgentMemoryTransport([childAnswer]);
        auto childRunner = new AgentSessionRunner(
            childTransport, new AgentToolRegistry(), new AgentPermissions(),
            AgentCredential("test-key", "http://127.0.0.1:1/v1"),
            toolProject, "ses-child", 4, "subagent-child");
        string answer;
        void collect(AgentEvent event)
        {
            if (event.type == AgentEventType.textDelta) answer ~= event.delta;
        }
        childRunner.run(task, childFile, &collect, cancelled,
                        delegate(AgentPermissionRequest) { return true; });
        return answer;
    }

    auto parentTools = new AgentToolRegistry(&runChild);
    JSONValue[string] subagentInput;
    subagentInput["description"] = JSONValue("answer a question");
    subagentInput["prompt"] = JSONValue("what is two plus two?");
    auto subagentResult = parentTools.execute("subagent",
        JSONValue(subagentInput), toolProject, null);
    if (!toolText(subagentResult).canFind("child answer"))
    {
        stderr.writeln("embedded subagent task failed");
        return 1;
    }

    // Project edits are staged as upstream-shaped revert patches and can be
    // undone byte-for-byte from the project's .dcad directory.
    auto patchProject = buildPath(workDir, "patch-project");
    mkdirRecurse(patchProject);
    write(buildPath(patchProject, "source.txt"), "one\ntwo\nthree\n");
    auto patchRecorder = new AgentChangeRecorder(patchProject);
    patchRecorder.capture("source.txt");
    write(buildPath(patchProject, "source.txt"), "one\nTWO\nthree\n");
    auto patchStore = new AgentPatchStore(patchProject);
    auto stagedPatch = patchStore.stage(patchRecorder, "msg-patch");
    auto revertData = revertEventData(stagedPatch);
    auto revertEvent = decodeAgentEvent(
        `{"event":"session.revert.staged","data":` ~ revertData.toString() ~ `}`);
    if (!stagedPatch.id.length || stagedPatch.files.length != 1 ||
        stagedPatch.files[0].additions != 1 ||
        stagedPatch.files[0].deletions != 1 ||
        !patchStore.patchText(stagedPatch.id).canFind("-two") ||
        !patchStore.patchText(stagedPatch.id).canFind("+TWO") ||
        revertEvent.type != AgentEventType.revertStaged ||
        revertEvent.revert.object["snapshot"].str != stagedPatch.id ||
        !patchStore.undo(stagedPatch.id) ||
        readText(buildPath(patchProject, "source.txt")) != "one\ntwo\nthree\n" ||
        patchStore.latest().id.length != 0)
    {
        stderr.writeln("project patch staging or undo failed");
        return 1;
    }

    // AgentBridge can run that same core asynchronously, draining events on
    // the GUI-thread API while the worker owns the transport.
    immutable savedHome = environment.get("HOME", "");
    scope(exit)
    {
        if (savedHome.length) environment["HOME"] = savedHome;
        else environment.remove("HOME");
    }
    immutable agentHome = buildPath(workDir, "agent-home");
    mkdirRecurse(agentHome);
    environment["HOME"] = agentHome;
    environment["DCAD_AGENT_API_KEY"] = "test-key";
    environment["DCAD_AGENT_BASE_URL"] = "http://127.0.0.1:1/v1";

    auto bridge = new AgentBridge();
    scope(exit)
    {
        bridge.close();
        bridge.persist();
    }
    bridge.useEmbedded(new AgentMemoryTransport([finalResponse]));
    bridge.open(toolProject, "tool-project");
    if (!bridge.send("hello bridge", "note.txt")) return 1;
    foreach (_; 0 .. 2000)
    {
        if (!bridge.busy) break;
        bridge.drain();
        Thread.sleep(dur!"msecs"(1));
    }
    bridge.drain();

    bool sawBridgeAnswer;
    foreach (message; bridge.messages)
        if (message.role == AgentRole.assistant &&
            message.text.canFind("Done"))
            sawBridgeAnswer = true;
    if (bridge.busy || !sawBridgeAnswer || bridge.status != "Agent ready")
    {
        stderr.writeln("async AgentBridge embedded core failed: ", bridge.status);
        return 1;
    }

    // A staged edit is reported to the GUI exactly once so an open editor can
    // reload it; undo restores the file and requests a second refresh.
    immutable refreshProject = buildPath(workDir, "refresh-project");
    mkdirRecurse(refreshProject);
    immutable refreshFile = buildPath(refreshProject, "edit.txt");
    write(refreshFile, "before\n");
    auto refreshToolResponse = ssePayload(
        `{"id":"c1","model":"opencode/big-pickle","choices":[{"index":0,` ~
        `"delta":{"tool_calls":[{"index":0,"id":"call_2","type":"function",` ~
        `"function":{"name":"write","arguments":` ~
        `"{\"file\":\"edit.txt\",\"content\":\"changed\"}"}}]},` ~
        `"finish_reason":"tool_calls"}]}`);
    auto refreshBridge = new AgentBridge();
    scope(exit) refreshBridge.close();
    refreshBridge.useEmbedded(new AgentMemoryTransport(
        [refreshToolResponse, finalResponse]));
    refreshBridge.open(refreshProject, "refresh-project");
    if (!refreshBridge.send("edit the open file", "edit.txt")) return 1;
    foreach (_; 0 .. 2000)
    {
        if (!refreshBridge.busy) break;
        refreshBridge.drain();
        Thread.sleep(dur!"msecs"(1));
    }
    refreshBridge.drain();
    auto refreshFiles = refreshBridge.patchFiles();
    auto refreshDiff = refreshBridge.patchDiff();
    if (refreshBridge.busy || !refreshBridge.hasPatch ||
        !refreshBridge.consumeEditorRefresh() ||
        refreshBridge.consumeEditorRefresh() ||
        refreshFiles.length != 1 || refreshFiles[0] != "edit.txt" ||
        !refreshDiff.canFind("-before") || !refreshDiff.canFind("+changed") ||
        !refreshBridge.undoLastChange() ||
        readText(refreshFile) != "before\n" ||
        !refreshBridge.consumeEditorRefresh() || refreshBridge.hasPatch)
    {
        stderr.writeln("agent patch editor refresh failed");
        return 1;
    }

    // SSE framing must survive chunks split inside a data line.
    auto sse = new AgentSSEParser();
    sse.push("data: {\"x\":\n");
    sse.push("data: 1}\n\n: ping\n\n");
    sse.push("event: message\ndata: {\"choices\":[]}\n\n");
    sse.push("data: [DONE]\n\n");
    AgentSSEEvent[] sseEvents;
    AgentSSEEvent sseEvent;
    while (sse.pop(sseEvent)) sseEvents ~= sseEvent;
    if (sseEvents.length != 3 ||
        sseEvents[0].data != "{\"x\":\n1}" ||
        sseEvents[1].name != "message" ||
        sseEvents[2].name != "[DONE]")
    {
        stderr.writeln("agent SSE framing failed");
        return 1;
    }

    // Credentials are dcad-owned: app-cache config plus env overrides, never
    // installed OpenCode auth and never a project file.
    immutable savedConfigDir = environment.get("DCAD_AGENT_CONFIG_DIR", "");
    immutable savedKey = environment.get("DCAD_AGENT_API_KEY", "");
    immutable savedURL = environment.get("DCAD_AGENT_BASE_URL", "");
    scope(exit)
    {
        if (savedConfigDir.length) environment["DCAD_AGENT_CONFIG_DIR"] = savedConfigDir;
        else environment.remove("DCAD_AGENT_CONFIG_DIR");
        if (savedKey.length) environment["DCAD_AGENT_API_KEY"] = savedKey;
        else environment.remove("DCAD_AGENT_API_KEY");
        if (savedURL.length) environment["DCAD_AGENT_BASE_URL"] = savedURL;
        else environment.remove("DCAD_AGENT_BASE_URL");
    }
    environment["DCAD_AGENT_CONFIG_DIR"] = buildPath(workDir, "agent-config");
    environment["DCAD_AGENT_API_KEY"] = "";
    environment["DCAD_AGENT_BASE_URL"] = "";
    auto credentials = new AgentCredentials();
    credentials.save(AgentCredential("test-key", "http://127.0.0.1:1/v1"));
    auto stored = credentials.load();
    environment["DCAD_AGENT_API_KEY"] = "env-key";
    auto overridden = credentials.load();
    if (!stored.hasKey || stored.apiKey != "test-key" ||
        stored.baseURL != "http://127.0.0.1:1/v1" ||
        overridden.apiKey != "env-key" ||
        defaultAgentBaseURL != "https://opencode.ai/inference/openai/v1")
    {
        stderr.writeln("dcad-owned credentials failed");
        return 1;
    }
    environment["DCAD_AGENT_API_KEY"] = "";

    // History is append-only, project-owned JSONL and tolerates a truncated
    // final line from an interrupted write.
    immutable historyProject = buildPath(workDir, "history-project");
    mkdirRecurse(historyProject);
    JSONValue[string] payload;
    payload["text"] = JSONValue("hello");
    appendAgentHistory(historyProject,
                       AgentHistoryEntry("", "ses-h", "", "user", JSONValue(payload)));
    appendAgentHistory(historyProject,
                       AgentHistoryEntry("", "ses-h", "ses-h", "assistant", JSONValue(payload)));
    append(agentHistoryFilePath(historyProject), "{truncated\n");
    auto entries = readAgentHistory(historyProject);
    if (entries.length != 2 ||
        entries[0].kind != "user" || entries[0].session != "ses-h" ||
        entries[1].parent != "ses-h" || entries[1].kind != "assistant" ||
        entries[0].timestamp.length == 0)
    {
        stderr.writeln("project history JSONL was not persisted");
        return 1;
    }

    // The transitional bridge mirrors its transcript into the same file.
    immutable mirrorProject = buildPath(workDir, "history-mirror");
    mkdirRecurse(mirrorProject);
    writeAgentHistorySnapshot(mirrorProject, "ses-mirror",
                              [AgentMessage(AgentRole.user, "mirrored", "")]);
    auto mirrored = readAgentHistory(mirrorProject);
    if (mirrored.length != 1 || mirrored[0].kind != "message" ||
        mirrored[0].data.object["role"].str != "user" ||
        mirrored[0].data.object["text"].str != "mirrored")
    {
        stderr.writeln("legacy transcript was not mirrored to project history");
        return 1;
    }

    immutable session = makeSessionId(project.root, 42);
    immutable history = agentHistoryFilePath(project.root);
    if (!session.startsWith("ses") ||
        !history.startsWith(project.root) ||
        baseName(history) != "history.jsonl" ||
        agentCacheDir().startsWith(project.root))
    {
        stderr.writeln("agent history is not project-local: ", session,
                       " / ", history);
        return 1;
    }

    // The fixed D LSP bridge uses Content-Length framing and a worker thread.
    // Split a frame at an arbitrary boundary to prove incremental decoding.
    auto framed = encodeLspMessage(lspNotification("initialized",
                                                  JSONValue.emptyObject));
    auto frameReader = new LspFrameReader();
    frameReader.push(framed[0 .. 13]);
    frameReader.push(framed[13 .. $]);
    JSONValue frameMessage;
    if (!frameReader.pop(frameMessage) ||
        frameMessage.object["method"].str != "initialized")
    {
        stderr.writeln("LSP Content-Length framing failed");
        return 1;
    }

    JSONValue[string] lspStart;
    lspStart["line"] = JSONValue(4);
    lspStart["character"] = JSONValue(9);
    JSONValue[string] lspRange;
    lspRange["start"] = JSONValue(lspStart);
    lspRange["end"] = JSONValue(lspStart);
    JSONValue[string] lspEntry;
    lspEntry["range"] = JSONValue(lspRange);
    lspEntry["severity"] = JSONValue(2);
    lspEntry["message"] = JSONValue("unknown identifier");
    JSONValue[string] lspParams;
    lspParams["uri"] = JSONValue(lspPathToURI(buildPath(workDir, "lsp.d")));
    lspParams["diagnostics"] = JSONValue([JSONValue(lspEntry)]);
    auto lspNotificationMessage = lspNotification(
        "textDocument/publishDiagnostics", JSONValue(lspParams));
    auto lspDiagnostics = parseLspDiagnostics(lspNotificationMessage);
    if (lspDiagnostics.length != 1 || lspDiagnostics[0].line != 4 ||
        lspDiagnostics[0].character != 9 || lspDiagnostics[0].severity != 2 ||
        !lspDiagnostics[0].message.canFind("unknown identifier"))
    {
        stderr.writeln("LSP diagnostic decoding failed");
        return 1;
    }

    JSONValue[string] completionItem;
    completionItem["label"] = JSONValue("writeln");
    completionItem["insertText"] = JSONValue("writeln");
    auto lspCompletions = parseLspCompletions(
        lspResponse(7, JSONValue([JSONValue(completionItem)])));
    if (lspCompletions.length != 1 || lspCompletions[0].label != "writeln" ||
        lspCompletions[0].insertText != "writeln")
    {
        stderr.writeln("LSP completion decoding failed");
        return 1;
    }

    auto lspChannel = new LspMemoryChannel();
    auto lspBridge = new DLspBridge(lspChannel);
    if (!lspBridge.start(workDir))
    {
        stderr.writeln("injected LSP bridge did not start");
        return 1;
    }
    lspBridge.openDocument("bridge.d", "module bridge;\n");
    lspBridge.requestCompletion("bridge.d", 1, 0);
    lspChannel.push(`{"jsonrpc":"2.0","id":1,"result":{}}`);
    lspChannel.push(lspNotificationMessage.toString());
    auto completionResponse = lspResponse(2, JSONValue([JSONValue(completionItem)]));
    lspChannel.push(completionResponse.toString());

    LspSnapshot lspSnapshot;
    foreach (attempt; 0 .. 200)
    {
        lspBridge.drain(lspSnapshot);
        if (lspSnapshot.diagnostics.length && lspSnapshot.completions.length)
            break;
        Thread.sleep(dur!"msecs"(5));
    }
    auto lspSent = lspChannel.sent();
    if (!lspSnapshot.running || lspSnapshot.diagnostics.length != 1 ||
        lspSnapshot.completions.length != 1 ||
        !lspSnapshot.completions[0].label.canFind("writeln") ||
        lspSent.length < 4 ||
        !lspSent[0].canFind("initialize") ||
        !lspSent[1].canFind("didOpen") ||
        !lspSent[2].canFind("completion"))
    {
        stderr.writeln("LSP bridge lifecycle failed");
        return 1;
    }
    lspBridge.shutdown();

    // The fixed bridge is fail-soft: a missing serve-d becomes a status line,
    // never a startup exception or an alternate language server.
    immutable savedLspExecutable =
        environment.get("DCAD_LSP_EXECUTABLE", "");
    scope(exit)
    {
        if (savedLspExecutable.length)
            environment["DCAD_LSP_EXECUTABLE"] = savedLspExecutable;
        else
            environment.remove("DCAD_LSP_EXECUTABLE");
    }
    environment["DCAD_LSP_EXECUTABLE"] = "dcad-no-such-serve-d-b7c4";
    auto missingLspBridge = new DLspBridge();
    if (missingLspBridge.start(workDir))
    {
        stderr.writeln("missing serve-d was incorrectly started");
        return 1;
    }
    LspSnapshot missingLspSnapshot;
    missingLspBridge.drain(missingLspSnapshot);
    if (!missingLspSnapshot.status.canFind("not found"))
    {
        stderr.writeln("missing serve-d status was not reported");
        return 1;
    }
    missingLspBridge.shutdown();

    // A missing compiler must become a visible script error, not an uncaught
    // exception that makes the packaged GUI exit with status 1.
    immutable savedPath = environment.get("PATH", "");
    scope(exit) environment["PATH"] = savedPath;
    environment["PATH"] = workDir;
    immutable bareWorkDir = buildPath(workDir, "no-compiler");
    mkdirRecurse(bareWorkDir);
    auto bareHost = new ScriptHost(bareWorkDir, workDir);
    auto noCompiler = bareHost.run(
        "Shape result = Workplane.create().box(1, 1, 1).shape;");
    if (noCompiler.ok() || noCompiler.error.length == 0 ||
        !noCompiler.error.canFind("ldc2"))
    {
        stderr.writeln("missing ldc2 was not reported: ", noCompiler.error);
        return 1;
    }

    writeln("PASS: script host forms, TOML scaffold, daimochi joint, embedded-agent core and slash commands");
    return 0;
}
