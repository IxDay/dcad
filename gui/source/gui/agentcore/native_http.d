/**
 * Flat C ABI for dcad's native streaming HTTP transport.
 *
 * The implementations live in gui/shim/ and are selected at shim build time:
 * WinHTTP on Windows, NSURLSession on macOS and libcurl on Linux. Chunk bytes
 * are borrowed and valid only for the duration of the callback.
 */
module gui.agentcore.native_http;

struct DcadHttpHeader
{
    const(char)* name;
    const(char)* value;
}

struct DcadHttpRequest
{
    const(char)* url;
    const(DcadHttpHeader)* headers;
    int headerCount;
    const(char)* body;
    size_t bodyLength;
    int timeoutSeconds;
}

struct DcadHttpResult
{
    int status;
    char* error;
}

/// Return nonzero to abort the response stream.
alias DcadHttpChunkFn = extern(C) int function(const(char)* bytes,
                                               size_t length, void* userData);

/// Return nonzero when the caller wants the request cancelled.
alias DcadHttpCancelFn = extern(C) int function(void* userData);

extern(C) nothrow @nogc
{
    int dcad_http_post_stream(const(DcadHttpRequest)* request,
                              DcadHttpChunkFn onChunk,
                              DcadHttpCancelFn cancelled,
                              void* userData,
                              DcadHttpResult* resultOut);

    void dcad_http_free_result(DcadHttpResult* result);
}
