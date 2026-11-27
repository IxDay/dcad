/**
 * OpenAI-compatible chat-completions client model for `opencode/big-pickle`.
 *
 * This module builds requests and normalizes streamed chunks; the actual HTTP
 * transport is kept separate so tests can drive it with SSE fixtures. Wire
 * shape follows vendor/opencode-v2.3.2/packages/ai/src/protocols/openai-chat.ts.
 */
module gui.agentcore.llm;

import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;
import gui.agentcore.schema : AgentFinishReason, AgentTokenUsage,
                              agentField, agentStringField,
                              agentUnsignedField, normalizeFinishReason,
                              parseAgentTokenUsage;

enum bigPickleModel = "opencode/big-pickle";

struct AgentChatMessage
{
    string role;
    string content;
    /// Tool result messages use tool_call_id.
    string toolCallID;
    JSONValue toolCalls;

    JSONValue toJSON()
    {
        JSONValue[string] object;
        object["role"] = JSONValue(role);
        if (content.length) object["content"] = JSONValue(content);
        if (toolCallID.length) object["tool_call_id"] = JSONValue(toolCallID);
        if (toolCalls.type != JSONType.null_) object["tool_calls"] = toolCalls;
        return JSONValue(object);
    }
}

struct AgentToolCallDelta
{
    int index;
    string id;
    string name;
    string arguments;
}

struct AgentCompletionChunk
{
    string id;
    string model;
    AgentFinishReason finishReason;
    string rawFinishReason;
    string deltaText;
    string reasoningText;
    AgentToolCallDelta[] toolCalls;
    AgentTokenUsage usage;

    bool hasToolCalls() const @property
    {
        return toolCalls.length != 0;
    }
}

string chatCompletionsURL(string baseURL)
{
    auto trimmed = strip(baseURL);
    while (trimmed.length && trimmed[$ - 1] == '/')
        trimmed = trimmed[0 .. $ - 1];
    return trimmed ~ "/chat/completions";
}

JSONValue makeChatRequest(string model, AgentChatMessage[] messages,
                          JSONValue tools = JSONValue.init)
{
    JSONValue[string] object;
    object["model"] = JSONValue(model.length ? model : bigPickleModel);
    object["stream"] = JSONValue(true);

    JSONValue[] encoded;
    foreach (message; messages) encoded ~= message.toJSON();
    object["messages"] = JSONValue(encoded);

    if (tools.type != JSONType.null_)
        object["tools"] = tools;

    return JSONValue(object);
}

bool isAgentStreamDone(string data)
{
    return strip(data) == "[DONE]";
}

AgentToolCallDelta parseAgentToolCallDelta(JSONValue value)
{
    AgentToolCallDelta result;
    result.index = cast(int) agentUnsignedField(value, "index");
    result.id = agentStringField(value, "id");

    auto fn = agentField(value, "function");
    if (fn.type == JSONType.object)
    {
        result.name = agentStringField(fn, "name");
        result.arguments = agentStringField(fn, "arguments");
    }
    return result;
}

/// Parse one non-[DONE] SSE `data` payload from /chat/completions.
AgentCompletionChunk parseChatCompletionChunk(string json)
{
    AgentCompletionChunk result;
    auto root = parseJSON(strip(json));
    result.id = agentStringField(root, "id");
    result.model = agentStringField(root, "model");

    auto choices = agentField(root, "choices");
    if (choices.type == JSONType.array && choices.array.length)
    {
        auto choice = choices.array[0];
        result.rawFinishReason = agentStringField(choice, "finish_reason");
        result.finishReason = normalizeFinishReason(result.rawFinishReason);

        auto delta = agentField(choice, "delta");
        result.deltaText = agentStringField(delta, "content");
        result.reasoningText = agentStringField(delta, "reasoning_content");
        if (!result.reasoningText.length)
            result.reasoningText = agentStringField(delta, "reasoning");

        auto calls = agentField(delta, "tool_calls");
        if (calls.type == JSONType.array)
            foreach (call; calls.array)
                result.toolCalls ~= parseAgentToolCallDelta(call);
    }

    result.usage = parseAgentTokenUsage(agentField(root, "usage"));
    return result;
}
