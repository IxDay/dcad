/**
 * Transport seam for the embedded agent.
 *
 * Production transports stream bytes from HTTPS into the SSE parser; tests use
 * the in-memory transport so the loop can be exercised without network or
 * credentials.
 */
module gui.agentcore.transport;

import std.algorithm : min;
import std.conv : to;

struct AgentHTTPRequest
{
    string url;
    string[string] headers;
    string body;
    ulong timeoutSeconds = 120;
}

struct AgentHTTPResult
{
    int status;
    string error;

    bool ok() const @property
    {
        return status >= 200 && status < 300 && error.length == 0;
    }
}

interface AgentTransport
{
    AgentHTTPResult stream(AgentHTTPRequest request,
                           scope void delegate(const(char)[] chunk) onChunk,
                           scope bool delegate() cancelled);
}

private string[] chunksOf(string text, size_t size)
{
    string[] result;
    for (size_t at = 0; at < text.length; at += size)
        result ~= text[at .. min(at + size, text.length)].idup;
    return result;
}

/// Deterministic transport used by tests and by headless fixtures.
final class AgentMemoryTransport : AgentTransport
{
    string[] responses;
    int status = 200;
    string error;
    size_t calls;
    AgentHTTPRequest lastRequest;
    string[string] lastHeaders;

    this(string[] responses = null)
    {
        this.responses = responses;
    }

    AgentHTTPResult stream(AgentHTTPRequest request,
                           scope void delegate(const(char)[] chunk) onChunk,
                           scope bool delegate() cancelled)
    {
        lastRequest = request;
        lastHeaders = request.headers;
        ++calls;

        if (error.length) return AgentHTTPResult(0, error);
        if (status < 200 || status >= 300)
            return AgentHTTPResult(status, "HTTP " ~ status.to!string);

        auto index = calls - 1;
        auto response = index < responses.length ? responses[index] : "";
        foreach (chunk; response.chunksOf(7))
        {
            if (cancelled()) return AgentHTTPResult(0, "cancelled");
            onChunk(chunk);
        }
        return AgentHTTPResult(status, null);
    }
}

/// Used until a real HTTPS transport is selected for a target.
final class AgentUnavailableTransport : AgentTransport
{
    AgentHTTPResult stream(AgentHTTPRequest,
                           scope void delegate(const(char)[]),
                           scope bool delegate())
    {
        return AgentHTTPResult(0,
            "No HTTPS transport is configured for this dcad build");
    }
}
