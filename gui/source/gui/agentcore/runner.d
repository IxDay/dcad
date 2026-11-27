/**
 * Synchronous session runner used by the worker thread.
 *
 * It owns one Big Pickle step loop: stream a response, normalize chunks into
 * canonical V2 events, execute permitted tools, and continue until the model
 * stops or the caller cancels. No GUI calls happen here.
 */
module gui.agentcore.runner;

import std.algorithm : sort;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

import gui.agentcore.credentials : AgentCredential;
import gui.agentcore.events : AgentEvent, decodeAgentEvent;
import gui.agentcore.llm : AgentChatMessage, bigPickleModel,
                           chatCompletionsURL, isAgentStreamDone,
                           makeChatRequest, parseChatCompletionChunk;
import gui.agentcore.patches : AgentChangeRecorder, AgentPatchStore,
                               revertEventData;
import gui.agentcore.permissions : AgentPermissionDecision, AgentPermissionRequest,
                                   AgentPermissions;
import gui.agentcore.schema : AgentFinishReason, agentBoolField, agentField,
                              agentStringField;
import gui.agentcore.sse : AgentSSEEvent, AgentSSEParser;
import gui.agentcore.tools : AgentToolRegistry;
import gui.agentcore.transport : AgentHTTPRequest, AgentTransport;

alias AgentPermissionApprover = bool delegate(AgentPermissionRequest request);

private struct PendingToolCall
{
    string id;
    string name;
    string arguments;
}

final class AgentSessionRunner
{
    private AgentTransport transport;
    private AgentToolRegistry tools;
    private AgentPermissions permissions;
    private AgentCredential credential;
    private string projectRoot;
    private string sessionId;
    private string assistantID;
    private size_t maxSteps;

    this(AgentTransport transport, AgentToolRegistry tools,
         AgentPermissions permissions, AgentCredential credential,
         string projectRoot, string sessionId, size_t maxSteps = 8,
         string assistantID = "a1")
    {
        this.transport = transport;
        this.tools = tools;
        this.permissions = permissions;
        this.credential = credential;
        this.projectRoot = projectRoot;
        this.sessionId = sessionId;
        this.assistantID = assistantID.length ? assistantID : "a1";
        this.maxSteps = maxSteps;
    }

    void run(string prompt, string activeFile,
             scope void delegate(AgentEvent) emit,
             scope bool delegate() cancelled,
             scope AgentPermissionApprover approve)
    {
        AgentChatMessage[] messages;
        messages ~= AgentChatMessage("system",
            "You are dcad's embedded coding agent. Work only inside the open "
            ~ "project. Prefer exact edits and explain changes briefly.");
        messages ~= AgentChatMessage("user",
            "Project root: " ~ projectRoot ~ "\nActive file: "
            ~ (activeFile.length ? activeFile : "(none)") ~ "\n\n" ~ strip(prompt));

        auto finish = AgentFinishReason.unknown;
        auto changes = new AgentChangeRecorder(projectRoot);
        bool failed;

        bool isCancelled()
        {
            return cancelled !is null && cancelled();
        }

        foreach (step; 0 .. maxSteps)
        {
            if (isCancelled()) return interrupted(emit);

            if (step == 0) emit(event("session.execution.started", baseData()));
            emit(event("session.step.started", baseData()));

            auto request = AgentHTTPRequest();
            request.url = chatCompletionsURL(credential.baseURL);
            request.headers["Authorization"] = "Bearer " ~ credential.apiKey;
            request.headers["Content-Type"] = "application/json";
            request.body = makeChatRequest(bigPickleModel, messages,
                                           JSONValue(tools.toolSchemas)).toString();

            auto parser = new AgentSSEParser();
            PendingToolCall[int] pendingCalls;
            size_t ordinal;
            string accumulated;

            void consumeData(string data)
            {
                if (isAgentStreamDone(data)) return;
                auto chunk = parseChatCompletionChunk(data);

                if (chunk.deltaText.length)
                {
                    JSONValue[string] dataObj = baseDataObject();
                    dataObj["assistantMessageID"] = JSONValue(assistantID);
                    dataObj["ordinal"] = JSONValue(cast(long) ordinal++);
                    dataObj["delta"] = JSONValue(chunk.deltaText);
                    emit(event("session.text.delta", JSONValue(dataObj)));
                    accumulated ~= chunk.deltaText;
                }
                if (chunk.reasoningText.length)
                {
                    JSONValue[string] dataObj = baseDataObject();
                    dataObj["assistantMessageID"] = JSONValue(assistantID);
                    dataObj["delta"] = JSONValue(chunk.reasoningText);
                    emit(event("session.reasoning.delta", JSONValue(dataObj)));
                }

                foreach (call; chunk.toolCalls)
                {
                    auto stored = call.index in pendingCalls;
                    if (stored is null)
                    {
                        pendingCalls[call.index] = PendingToolCall(
                            call.id, call.name, call.arguments);
                    }
                    else
                    {
                        if (call.id.length) stored.id = call.id;
                        if (call.name.length) stored.name = call.name;
                        if (call.arguments.length) stored.arguments ~= call.arguments;
                    }
                }

                if (chunk.finishReason != AgentFinishReason.unknown)
                    finish = chunk.finishReason;
            }

            void consumeChunk(const(char)[] bytes)
            {
                parser.push(bytes);
                AgentSSEEvent parsed;
                while (parser.pop(parsed))
                    if (parsed.data.length) consumeData(parsed.data);
            }

            auto result = transport.stream(request, &consumeChunk, &isCancelled);
            if (isCancelled()) return interrupted(emit);

            if (!result.ok)
            {
                JSONValue[string] dataObj = baseDataObject();
                dataObj["error"] = JSONValue(result.error.length
                    ? result.error : "model request failed");
                emit(event("session.execution.failed", JSONValue(dataObj)));
                return;
            }

            emit(event("session.step.ended", baseData()));
            messages ~= AgentChatMessage("assistant", accumulated);

            if (finish == AgentFinishReason.toolCalls && pendingCalls.length)
            {
                executeCalls(pendingCalls, messages, emit, &isCancelled, approve,
                             changes);
                finish = AgentFinishReason.unknown;
                continue;
            }

            if (finish == AgentFinishReason.error ||
                finish == AgentFinishReason.contentFilter)
            {
                stageChanges(changes, emit);
                JSONValue[string] dataObj = baseDataObject();
                dataObj["error"] = JSONValue("model finished with "
                    ~ finishReasonText(finish));
                emit(event("session.execution.failed", JSONValue(dataObj)));
                return;
            }

            stageChanges(changes, emit);
            emit(event("session.execution.succeeded", baseData()));
            emit(event("session.idle", baseData()));
            return;
        }

        failed = true;
        if (failed)
        {
            stageChanges(changes, emit);
            JSONValue[string] dataObj = baseDataObject();
            dataObj["error"] = JSONValue("agent step limit reached");
            emit(event("session.step.failed", JSONValue(dataObj)));
            emit(event("session.execution.failed", JSONValue(dataObj)));
        }
    }

    private JSONValue[string] baseDataObject()
    {
        JSONValue[string] data;
        data["sessionID"] = JSONValue(sessionId);
        return data;
    }

    private JSONValue baseData()
    {
        return JSONValue(baseDataObject());
    }

    private AgentEvent event(string name, JSONValue data)
    {
        JSONValue[string] envelope;
        envelope["event"] = JSONValue(name);
        envelope["data"] = data;
        return decodeAgentEvent(JSONValue(envelope).toString());
    }

    private string finishReasonText(AgentFinishReason reason)
    {
        final switch (reason)
        {
            case AgentFinishReason.stop: return "stop";
            case AgentFinishReason.length: return "length";
            case AgentFinishReason.toolCalls: return "tool-calls";
            case AgentFinishReason.contentFilter: return "content-filter";
            case AgentFinishReason.error: return "error";
            case AgentFinishReason.unknown: return "unknown";
        }
    }

    private void interrupted(scope void delegate(AgentEvent) emit)
    {
        emit(event("session.execution.interrupted", baseData()));
    }

    private void stageChanges(AgentChangeRecorder changes,
                              scope void delegate(AgentEvent) emit)
    {
        if (changes is null || !changes.hasChanges()) return;
        auto store = new AgentPatchStore(projectRoot);
        auto staged = store.stage(changes, sessionId);
        if (staged.id.length)
            emit(event("session.revert.staged", revertEventData(staged)));
    }

    private void executeCalls(ref PendingToolCall[int] calls,
                              ref AgentChatMessage[] messages,
                              scope void delegate(AgentEvent) emit,
                              scope bool delegate() cancelled,
                              scope AgentPermissionApprover approve,
                              AgentChangeRecorder changes)
    {
        auto indexes = calls.keys;
        sort(indexes);

        foreach (index; indexes)
        {
            auto call = calls[index];
            if (cancelled !is null && cancelled()) return interrupted(emit);

            JSONValue parsedInput = JSONValue.emptyObject;
            if (call.arguments.length)
            {
                try parsedInput = parseJSON(call.arguments);
                catch (Exception) { /* keep empty object */ }
            }

            auto called = baseDataObject();
            called["id"] = JSONValue(call.id);
            called["name"] = JSONValue(call.name);
            called["status"] = JSONValue("running");
            called["input"] = parsedInput;
            emit(event("session.tool.called", JSONValue(called)));

            auto request = AgentPermissionRequest();
            request.id = call.id;
            request.sessionID = sessionId;
            request.action = permissionAction(call.name);
            request.resources = [call.arguments];
            request.message = call.name;

            auto decision = permissions.decide(request.action, request.resources);
            bool allowed = decision.allowed();
            if (decision.needsAsk())
            {
                emit(event("permission.asked", JSONValue(called)));
                allowed = approve !is null && approve(request);
                auto replied = baseDataObject();
                replied["id"] = JSONValue(call.id);
                replied["reply"] = JSONValue(allowed ? "once" : "reject");
                emit(event("permission.replied", JSONValue(replied)));
            }

            JSONValue result;
            if (allowed && !decision.denied())
                result = tools.execute(call.name, parsedInput, projectRoot,
                                       cancelled, changes);
            else
            {
                JSONValue[string] content;
                content["type"] = JSONValue("text");
                content["text"] = JSONValue("permission denied");
                JSONValue[] contents = [JSONValue(content)];
                JSONValue[string] denied;
                denied["content"] = JSONValue(contents);
                denied["isError"] = JSONValue(true);
                result = JSONValue(denied);
            }

            auto finished = baseDataObject();
            finished["id"] = JSONValue(call.id);
            finished["name"] = JSONValue(call.name);
            auto erroneous = agentBoolField(result, "isError");
            if (erroneous)
            {
                finished["error"] = JSONValue(toolResultText(result));
                emit(event("session.tool.failed", JSONValue(finished)));
            }
            else
            {
                finished["output"] = JSONValue(toolResultText(result));
                emit(event("session.tool.success", JSONValue(finished)));
            }

            JSONValue[string] functionObj;
            functionObj["name"] = JSONValue(call.name);
            functionObj["arguments"] = JSONValue(call.arguments.length
                ? call.arguments : "{}");
            JSONValue[string] toolCall;
            toolCall["id"] = JSONValue(call.id);
            toolCall["type"] = JSONValue("function");
            toolCall["function"] = JSONValue(functionObj);
            messages ~= AgentChatMessage("assistant", "", "",
                                         JSONValue([JSONValue(toolCall)]));
            messages ~= AgentChatMessage("tool", toolResultText(result), call.id);
        }
    }

    private string toolResultText(JSONValue result)
    {
        auto content = agentField(result, "content");
        if (content.type == JSONType.array && content.array.length)
            return agentStringField(content.array[0], "text");
        return result.toString();
    }

    private string permissionAction(string tool)
    {
        switch (tool)
        {
            case "read":
            case "write":
            case "edit":
            case "glob":
            case "grep":
            case "shell":
            case "subagent":
                return tool;
            default:
                return "*";
        }
    }
}
