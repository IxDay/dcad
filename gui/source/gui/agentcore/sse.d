/**
 * Minimal SSE framer for OpenAI-compatible chat-completions streams.
 *
 * Fed arbitrary transport chunks so a `data:` line split across reads still
 * produces one event. `[DONE]` is surfaced as an event named "[DONE]".
 */
module gui.agentcore.sse;

import std.string : indexOf;

struct AgentSSEEvent
{
    string id;
    string name;
    string data;
}

final class AgentSSEParser
{
    private string buffer;
    private string id;
    private string name;
    private string data;

    /// Append bytes received from the transport and consume every complete line.
    void push(const(char)[] chunk)
    {
        buffer ~= chunk.idup;

        size_t newline;
        while ((newline = buffer.indexOf('\n')) != size_t.max)
        {
            auto line = buffer[0 .. newline];
            buffer = buffer[newline + 1 .. $].idup;
            consumeLine(line);
        }
    }

    /// Retrieve the next complete event, if any.
    bool pop(ref AgentSSEEvent event)
    {
        if (!pending.length) return false;
        event = pending[0];
        pending = pending[1 .. $].dup;
        return true;
    }

    private void consumeLine(const(char)[] rawLine)
    {
        auto line = rawLine;
        if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];

        if (!line.length)
        {
            dispatch();
            return;
        }
        // SSE comments and keep-alives start with ':'.
        if (line[0] == ':') return;

        auto colon = line.indexOf(':');
        const(char)[] field = colon == size_t.max ? line : line[0 .. colon];
        const(char)[] value = colon == size_t.max ? "" : line[colon + 1 .. $];
        if (value.length && value[0] == ' ') value = value[1 .. $];

        switch (field)
        {
            case "id":
                id = value.idup;
                break;
            case "event":
                name = value.idup;
                break;
            case "data":
                if (data.length) data ~= "\n";
                data ~= value.idup;
                break;
            default:
                break;
        }
    }

    private void dispatch()
    {
        if (!data.length && !name.length && !id.length) return;
        if (!name.length && data == "[DONE]") name = "[DONE]";
        // pop() consumes the pending event; no queue is needed because the
        // caller drains after each push in practice. Multiple complete events
        // in one push are kept in order by the pending-event fields.
        pending ~= AgentSSEEvent(id, name, data);
        id = null;
        name = null;
        data = null;
    }

    private AgentSSEEvent[] pending;
}
