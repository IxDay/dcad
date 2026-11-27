/**
 * D-side wrapper around dcad's native streaming HTTP shim.
 *
 * Used only by :gui so headless tests keep linking without platform network
 * libraries. The GUI worker thread owns this transport.
 */
module gui.agentcore.native_transport;

import std.string : fromStringz, toStringz;
import gui.agentcore.native_http;
import gui.agentcore.transport : AgentHTTPRequest, AgentHTTPResult, AgentTransport;

private struct CallbackContext
{
    void delegate(const(char)[]) onChunk;
    bool delegate() cancelled;
}

private extern(C) int chunkThunk(const(char)* bytes, size_t length,
                                 void* userData) nothrow
{
    auto context = cast(CallbackContext*) userData;
    if (context is null || context.onChunk is null) return 1;
    try
    {
        context.onChunk(bytes[0 .. length]);
        return 0;
    }
    catch (Throwable)
        return 1;
}

private extern(C) int cancelThunk(void* userData) nothrow
{
    auto context = cast(CallbackContext*) userData;
    if (context is null || context.cancelled is null) return 0;
    try
        return context.cancelled() ? 1 : 0;
    catch (Throwable)
        return 1;
}

final class AgentNativeTransport : AgentTransport
{
    AgentHTTPResult stream(AgentHTTPRequest request,
                           scope void delegate(const(char)[]) onChunk,
                           scope bool delegate() cancelled)
    {
        const(char)*[] retained;
        retained ~= cast(const(char)*) toStringz(request.url);
        retained ~= cast(const(char)*) toStringz(request.body);

        DcadHttpHeader[] headers;
        foreach (name, value; request.headers)
        {
            auto nameZ = cast(const(char)*) toStringz(name);
            auto valueZ = cast(const(char)*) toStringz(value);
            retained ~= nameZ;
            retained ~= valueZ;
            headers ~= DcadHttpHeader(nameZ, valueZ);
        }

        CallbackContext context;
        context.onChunk = onChunk;
        context.cancelled = cancelled;

        DcadHttpRequest nativeRequest;
        nativeRequest.url = retained[0];
        nativeRequest.headers = headers.ptr;
        nativeRequest.headerCount = cast(int) headers.length;
        nativeRequest.body = retained[1];
        nativeRequest.bodyLength = request.body.length;
        nativeRequest.timeoutSeconds = cast(int) request.timeoutSeconds;

        DcadHttpResult nativeResult;
        nativeResult.status = 0;
        nativeResult.error = null;
        immutable code = dcad_http_post_stream(&nativeRequest, &chunkThunk,
                                               &cancelThunk, &context,
                                               &nativeResult);

        string error;
        if (nativeResult.error !is null)
            error = fromStringz(nativeResult.error).idup;
        dcad_http_free_result(&nativeResult);

        if (code != 0 && !error.length)
            error = "native HTTP setup failed";
        return AgentHTTPResult(nativeResult.status, error);
    }
}
