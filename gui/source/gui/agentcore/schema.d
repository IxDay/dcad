/**
 * D projection of the OpenCode V2 schemas needed by the embedded Big Pickle
 * port. Field names mirror upstream JSON so fixtures from the pinned source can
 * be used directly in tests.
 *
 * Ported from vendor/opencode-v2.3.2/packages/schema/src/{session,
 * session-message,llm,model,tool}.ts.
 */
module gui.agentcore.schema;

import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : strip, toLower;

enum AgentFinishReason
{
    stop,
    length,
    toolCalls,
    contentFilter,
    error,
    unknown
}

enum AgentToolStatus
{
    streaming,
    running,
    completed,
    failed
}

enum AgentPartKind
{
    text,
    reasoning,
    tool
}

struct AgentModelRef
{
    string id;
    string providerID;
    string variant;
}

struct AgentTokenUsage
{
    ulong input;
    ulong output;
    ulong reasoning;
    ulong cacheRead;
    ulong cacheWrite;
}

struct AgentToolContent
{
    string type;
    string text;
    JSONValue raw;
}

struct AgentToolState
{
    AgentToolStatus status;
    /// ToolState.Streaming carries the partial JSON arguments as a string.
    string streamingInput;
    JSONValue input;
    string errorMessage;
    AgentToolContent[] content;
}

struct AgentToolCall
{
    string id;
    string name;
    bool executed;
    AgentToolState state;
}

struct AgentAssistantPart
{
    AgentPartKind kind;
    string text;
    AgentToolCall tool;
}

struct AgentSessionInfo
{
    string id;
    string parentID;
    string projectID;
    string title;
    string outcome;
    string directory;
    AgentModelRef model;
    AgentTokenUsage tokens;
    JSONValue time;
    JSONValue metadata;
    JSONValue permissions;
    JSONValue revert;
}

struct AgentPromptInput
{
    /// Idempotency key from Session.Message.ID.
    string id;
    string text;
    /// "steer" or "queue"; empty means upstream default.
    string delivery;
    /// false admits the message without starting the runner.
    bool resume = true;
}

JSONValue agentField(JSONValue value, string key)
{
    if (value.type == JSONType.object)
        if (auto found = key in value.object)
            return *found;
    return JSONValue.init;
}

string agentString(JSONValue value, string fallback = "")
{
    if (value.type == JSONType.string) return value.str;
    if (value.type == JSONType.null_) return fallback;
    return value.toString();
}

string agentStringField(JSONValue value, string key, string fallback = "")
{
    return agentString(agentField(value, key), fallback);
}

ulong agentUnsigned(JSONValue value)
{
    final switch (value.type)
    {
        case JSONType.integer:
            return value.integer < 0 ? 0 : cast(ulong) value.integer;
        case JSONType.uinteger:
            return value.uinteger;
        case JSONType.string:
            try return to!ulong(strip(value.str));
            catch (Exception) return 0;
        case JSONType.null_:
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.float_:
        case JSONType.array:
        case JSONType.object:
            return 0;
    }
}

ulong agentUnsignedField(JSONValue value, string key)
{
    return agentUnsigned(agentField(value, key));
}

bool agentBool(JSONValue value, bool fallback = false)
{
    final switch (value.type)
    {
        case JSONType.true_: return true;
        case JSONType.false_: return false;
        case JSONType.null_:
        case JSONType.string:
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
        case JSONType.array:
        case JSONType.object:
            return fallback;
    }
}

bool agentBoolField(JSONValue value, string key, bool fallback = false)
{
    return agentBool(agentField(value, key), fallback);
}

/// OpenAI raw finish reasons are normalized to V2 names before entering the
/// session state machine.
AgentFinishReason normalizeFinishReason(string raw)
{
    switch (toLower(strip(raw)))
    {
        case "stop": return AgentFinishReason.stop;
        case "length": return AgentFinishReason.length;
        case "tool_calls":
        case "tool-calls":
        case "tool calls":
            return AgentFinishReason.toolCalls;
        case "content_filter":
        case "content-filter":
            return AgentFinishReason.contentFilter;
        case "error": return AgentFinishReason.error;
        default: return AgentFinishReason.unknown;
    }
}

string finishReasonName(AgentFinishReason reason)
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

AgentModelRef parseAgentModelRef(JSONValue value)
{
    AgentModelRef result;
    result.id = agentStringField(value, "id");
    result.providerID = agentStringField(value, "providerID");
    result.variant = agentStringField(value, "variant");
    return result;
}

AgentTokenUsage parseAgentTokenUsage(JSONValue value)
{
    AgentTokenUsage result;
    result.input = agentUnsignedField(value, "input");
    result.output = agentUnsignedField(value, "output");
    result.reasoning = agentUnsignedField(value, "reasoning");

    auto cache = agentField(value, "cache");
    result.cacheRead = agentUnsignedField(cache, "read");
    result.cacheWrite = agentUnsignedField(cache, "write");
    return result;
}

AgentToolContent[] parseAgentToolContent(JSONValue value)
{
    AgentToolContent[] result;
    if (value.type != JSONType.array) return result;

    foreach (item; value.array)
    {
        AgentToolContent content;
        if (item.type == JSONType.string)
        {
            content.type = "text";
            content.text = item.str;
        }
        else
        {
            content.type = agentStringField(item, "type", "text");
            content.text = agentStringField(item, "text");
            content.raw = item;
        }
        result ~= content;
    }
    return result;
}

AgentToolState parseAgentToolState(JSONValue value)
{
    AgentToolState result;
    result.input = agentField(value, "input");
    result.content = parseAgentToolContent(agentField(value, "content"));

    switch (agentStringField(value, "status"))
    {
        case "streaming":
            result.status = AgentToolStatus.streaming;
            result.streamingInput = agentStringField(value, "input");
            break;
        case "running":
            result.status = AgentToolStatus.running;
            break;
        case "completed":
            result.status = AgentToolStatus.completed;
            break;
        case "error":
        case "failed":
            result.status = AgentToolStatus.failed;
            result.errorMessage = agentStringField(
                agentField(value, "error"), "message");
            if (!result.errorMessage.length)
                result.errorMessage = agentStringField(value, "error");
            break;
        default:
            result.status = AgentToolStatus.running;
            break;
    }
    return result;
}

AgentToolCall parseAgentToolCall(JSONValue value)
{
    AgentToolCall result;
    result.id = agentStringField(value, "id");
    result.name = agentStringField(value, "name");
    result.executed = agentBoolField(value, "executed");
    result.state = parseAgentToolState(agentField(value, "state"));
    return result;
}

AgentAssistantPart[] parseAssistantContent(JSONValue value)
{
    AgentAssistantPart[] result;
    if (value.type != JSONType.array) return result;

    foreach (part; value.array)
    {
        AgentAssistantPart parsed;
        auto kind = agentStringField(part, "type");
        switch (kind)
        {
            case "text":
                parsed.kind = AgentPartKind.text;
                parsed.text = agentStringField(part, "text");
                break;
            case "reasoning":
                parsed.kind = AgentPartKind.reasoning;
                parsed.text = agentStringField(part, "text");
                break;
            case "tool":
                parsed.kind = AgentPartKind.tool;
                parsed.tool = parseAgentToolCall(part);
                break;
            default:
                continue;
        }
        result ~= parsed;
    }
    return result;
}

AgentSessionInfo parseAgentSessionInfo(JSONValue value)
{
    AgentSessionInfo result;
    result.id = agentStringField(value, "id");
    result.parentID = agentStringField(value, "parentID");
    result.projectID = agentStringField(value, "projectID");
    result.title = agentStringField(value, "title");
    result.outcome = agentStringField(value, "outcome");
    result.model = parseAgentModelRef(agentField(value, "model"));
    result.tokens = parseAgentTokenUsage(agentField(value, "tokens"));
    result.time = agentField(value, "time");
    result.metadata = agentField(value, "metadata");
    result.permissions = agentField(value, "permissions");
    result.revert = agentField(value, "revert");
    result.directory = agentStringField(agentField(value, "location"), "directory");
    return result;
}

AgentPromptInput parseAgentPromptInput(JSONValue value)
{
    AgentPromptInput result;
    result.id = agentStringField(value, "id");
    result.text = agentStringField(value, "text");
    result.delivery = agentStringField(value, "delivery");
    if (value.type == JSONType.object)
        if (auto resume = "resume" in value.object)
            result.resume = agentBool(*resume, true);
    return result;
}
