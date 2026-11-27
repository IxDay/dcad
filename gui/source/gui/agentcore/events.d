/**
 * Canonical OpenCode V2 event projection for the embedded agent core.
 *
 * The legacy CLI adapter in gui.agent still understands short names such as
 * "text" and "tool_use"; this module speaks the V2 event names used by the
 * pinned source and maps them onto the flattened Agent transcript.
 */
module gui.agentcore.events;

import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;
import gui.agentcore.messages : AgentMessage, AgentRole;
import gui.agentcore.schema : agentField, agentStringField, agentUnsignedField;

enum AgentEventType
{
    serverConnected,
    executionStarted,
    executionSucceeded,
    executionFailed,
    executionInterrupted,
    stepStarted,
    stepFirstToken,
    stepStreamed,
    stepEnded,
    stepFailed,
    textDelta,
    reasoningDelta,
    toolInputStarted,
    toolInputDelta,
    toolInputEnded,
    toolCalled,
    toolProgress,
    toolSuccess,
    toolFailed,
    permissionAsked,
    permissionReplied,
    sessionIdle,
    revertStaged,
    revertCleared,
    revertCommitted,
    unknown
}

struct AgentEvent
{
    bool ok;
    AgentEventType type;
    string name;
    string sessionID;
    string assistantMessageID;
    string parentID;
    string id;
    string toolID;
    string toolName;
    string toolStatus;
    string delta;
    string detail;
    string error;
    ulong ordinal;
    JSONValue data;
    /// Nested V2 `Revert` payload for session.revert.* events.
    JSONValue revert;
}

AgentEventType agentEventType(string name)
{
    switch (name)
    {
        case "server.connected": return AgentEventType.serverConnected;
        case "session.execution.started": return AgentEventType.executionStarted;
        case "session.execution.succeeded": return AgentEventType.executionSucceeded;
        case "session.execution.failed": return AgentEventType.executionFailed;
        case "session.execution.interrupted": return AgentEventType.executionInterrupted;
        case "session.step.started": return AgentEventType.stepStarted;
        case "session.step.first-token": return AgentEventType.stepFirstToken;
        case "session.step.streamed": return AgentEventType.stepStreamed;
        case "session.step.ended": return AgentEventType.stepEnded;
        case "session.step.failed": return AgentEventType.stepFailed;
        case "session.text.delta": return AgentEventType.textDelta;
        case "session.reasoning.delta": return AgentEventType.reasoningDelta;
        case "session.tool.input.started": return AgentEventType.toolInputStarted;
        case "session.tool.input.delta": return AgentEventType.toolInputDelta;
        case "session.tool.input.ended": return AgentEventType.toolInputEnded;
        case "session.tool.called": return AgentEventType.toolCalled;
        case "session.tool.progress": return AgentEventType.toolProgress;
        case "session.tool.success": return AgentEventType.toolSuccess;
        case "session.tool.failed": return AgentEventType.toolFailed;
        case "permission.asked": return AgentEventType.permissionAsked;
        case "permission.replied": return AgentEventType.permissionReplied;
        case "session.idle": return AgentEventType.sessionIdle;
        case "session.revert.staged": return AgentEventType.revertStaged;
        case "session.revert.cleared": return AgentEventType.revertCleared;
        case "session.revert.committed": return AgentEventType.revertCommitted;
        default: return AgentEventType.unknown;
    }
}

/// Decode one SSE `data` payload from the V2 event stream. Both the canonical
/// `{ "event": ..., "data": ... }` envelope and a flat fixture shape are
/// accepted so golden fixtures from upstream remain readable.
AgentEvent decodeAgentEvent(string line)
{
    AgentEvent result;
    try
    {
        auto root = parseJSON(strip(line));
        result.ok = true;
        result.name = agentStringField(root, "event");
        if (!result.name.length) result.name = agentStringField(root, "type");

        auto data = agentField(root, "data");
        if (data.type == JSONType.null_ ||
            (data.type == JSONType.object && data.object.length == 0))
            data = root;
        result.data = data;
        result.type = agentEventType(result.name);

        result.sessionID = agentStringField(data, "sessionID");
        result.assistantMessageID = agentStringField(data, "assistantMessageID");
        result.parentID = agentStringField(data, "parentID");
        result.id = agentStringField(data, "id");
        result.toolID = agentStringField(data, "toolID");
        if (!result.toolID.length) result.toolID = agentStringField(data, "id");
        result.toolName = agentStringField(data, "name");
        if (!result.toolName.length) result.toolName = agentStringField(data, "tool");
        result.toolStatus = agentStringField(data, "status");
        result.delta = agentStringField(data, "delta");
        result.detail = agentStringField(data, "output");
        if (!result.detail.length) result.detail = agentStringField(data, "message");
        result.error = agentStringField(agentField(data, "error"), "message");
        if (!result.error.length) result.error = agentStringField(data, "error");
        result.ordinal = agentUnsignedField(data, "ordinal");
        result.revert = agentField(data, "revert");
    }
    catch (Exception e)
    {
        result.ok = false;
        result.type = AgentEventType.unknown;
        result.error = e.msg;
    }
    return result;
}

private string truncateDetail(string text)
{
    enum limit = 1600;
    if (text.length <= limit) return text;
    return text[0 .. limit] ~ "...";
}

private void appendMessage(ref AgentMessage[] messages, AgentRole role,
                           string text, string key)
{
    messages ~= AgentMessage(role, text, key);
    if (messages.length > 500)
        messages = messages[$ - 500 .. $].dup;
}

private void appendToolMessage(ref AgentMessage[] messages, string key,
                               string name, string status, string detail)
{
    auto text = "Tool " ~ (name.length ? name : "tool");
    if (status.length) text ~= " (" ~ status ~ ")";
    if (detail.length) text ~= "\n" ~ truncateDetail(detail);

    foreach (ref message; messages)
    {
        if (message.role == AgentRole.tool && message.key == key)
        {
            message.text = text;
            return;
        }
    }
    appendMessage(messages, AgentRole.tool, text, key);
}

private string revertID(AgentEvent event)
{
    if (event.id.length) return event.id;
    auto snapshot = agentStringField(event.revert, "snapshot");
    if (snapshot.length) return snapshot;
    return agentStringField(event.revert, "messageID");
}

private size_t revertFileCount(AgentEvent event)
{
    auto files = agentField(event.revert, "files");
    return files.type == JSONType.array ? files.array.length : 0;
}

/// Project an event onto the UI transcript. Returns true when the transcript
/// or status string changed.
bool projectAgentEvent(AgentEvent event, ref AgentMessage[] messages,
                       ref string status)
{
    final switch (event.type)
    {
        case AgentEventType.textDelta:
        case AgentEventType.reasoningDelta:
            if (!event.delta.length) return false;
            {
                auto key = event.assistantMessageID.length
                    ? event.assistantMessageID : "assistant";
                if (event.type == AgentEventType.reasoningDelta)
                    key = "reasoning:" ~ key;
                if (messages.length && messages[$ - 1].role == AgentRole.assistant &&
                    messages[$ - 1].key == key)
                    messages[$ - 1].text ~= event.delta;
                else
                    appendMessage(messages, AgentRole.assistant, event.delta, key);
            }
            status = "Agent working...";
            return true;

        case AgentEventType.toolInputStarted:
        case AgentEventType.toolInputDelta:
        case AgentEventType.toolInputEnded:
        case AgentEventType.toolCalled:
        case AgentEventType.toolProgress:
        case AgentEventType.toolSuccess:
        case AgentEventType.toolFailed:
            {
                auto toolStatus = event.toolStatus;
                if (!toolStatus.length)
                {
                    final switch (event.type)
                    {
                        case AgentEventType.toolInputStarted:
                        case AgentEventType.toolInputDelta:
                        case AgentEventType.toolInputEnded:
                        case AgentEventType.toolCalled:
                            toolStatus = "running";
                            break;
                        case AgentEventType.toolProgress:
                            toolStatus = "progress";
                            break;
                        case AgentEventType.toolSuccess:
                            toolStatus = "completed";
                            break;
                        case AgentEventType.toolFailed:
                            toolStatus = "error";
                            break;
                        case AgentEventType.textDelta:
                        case AgentEventType.reasoningDelta:
                        case AgentEventType.executionStarted:
                        case AgentEventType.executionSucceeded:
                        case AgentEventType.executionFailed:
                        case AgentEventType.executionInterrupted:
                        case AgentEventType.stepStarted:
                        case AgentEventType.stepFirstToken:
                        case AgentEventType.stepStreamed:
                        case AgentEventType.stepEnded:
                        case AgentEventType.stepFailed:
                        case AgentEventType.permissionAsked:
                        case AgentEventType.permissionReplied:
                        case AgentEventType.sessionIdle:
                        case AgentEventType.serverConnected:
                        case AgentEventType.revertStaged:
                        case AgentEventType.revertCleared:
                        case AgentEventType.revertCommitted:
                        case AgentEventType.unknown:
                            toolStatus = "";
                            break;
                    }
                }
                auto detail = event.detail;
                if (!detail.length) detail = event.error;
                auto key = event.toolID.length ? event.toolID : event.id;
                appendToolMessage(messages, key, event.toolName, toolStatus, detail);
            }
            status = "Agent working...";
            return true;

        case AgentEventType.permissionAsked:
            appendMessage(messages, AgentRole.status,
                          "Permission required: " ~ (event.detail.length ? event.detail : "tool use"),
                          "permission:" ~ event.id);
            status = "Permission required";
            return true;

        case AgentEventType.permissionReplied:
            status = "Agent working...";
            return true;

        case AgentEventType.executionStarted:
        case AgentEventType.stepStarted:
        case AgentEventType.stepFirstToken:
        case AgentEventType.stepStreamed:
        case AgentEventType.serverConnected:
            status = "Agent working...";
            return true;

        case AgentEventType.stepEnded:
        case AgentEventType.executionSucceeded:
        case AgentEventType.sessionIdle:
            status = "Agent ready";
            return true;

        case AgentEventType.executionFailed:
        case AgentEventType.stepFailed:
            appendMessage(messages, AgentRole.error,
                          event.error.length ? event.error : "Agent step failed",
                          "error:" ~ event.id);
            status = "Agent error";
            return true;

        case AgentEventType.executionInterrupted:
            appendMessage(messages, AgentRole.status, "Agent interrupted",
                          "interrupt:" ~ event.id);
            status = "Agent stopped";
            return true;

        case AgentEventType.revertStaged:
            appendMessage(messages, AgentRole.status,
                          "Change staged: " ~ revertFileCount(event).to!string
                          ~ " file(s). Use Undo to restore before the edit.",
                          "revert:" ~ revertID(event));
            status = "Agent ready";
            return true;

        case AgentEventType.revertCleared:
            appendMessage(messages, AgentRole.status, "Change kept",
                          "revert:" ~ revertID(event));
            status = "Agent ready";
            return true;

        case AgentEventType.revertCommitted:
            appendMessage(messages, AgentRole.status, "Change undone",
                          "revert:" ~ revertID(event));
            status = "Agent ready";
            return true;

        case AgentEventType.unknown:
            return false;
    }
}
