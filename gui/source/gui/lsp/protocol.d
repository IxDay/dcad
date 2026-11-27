/**
 * Minimal JSON-RPC 2.0 framing and D language-server protocol shapes.
 *
 * dcad uses only the fixed `serve-d` bridge in bridge.d. This module contains
 * no server discovery, no plugin/MCP decoding and no ImGui dependencies so the
 * wire format can be tested headlessly.
 */
module gui.lsp.protocol;

import std.algorithm : startsWith;
import std.array : appender;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, strip, toLower;

import gui.agentcore.schema : agentField, agentString, agentStringField,
                              agentUnsignedField;

struct LspPosition
{
    long line;
    long character;
}

struct LspRange
{
    LspPosition start;
    LspPosition end;
}

struct LspDiagnostic
{
    string path;
    long line;
    long character;
    long severity;
    string message;
}

struct LspCompletionItem
{
    string label;
    string insertText;
    string detail;
}

/// Encode one JSON-RPC message with LSP Content-Length framing.
string encodeLspMessage(JSONValue value)
{
    immutable body = value.toString();
    return "Content-Length: " ~ body.length.to!string ~ "\r\n\r\n" ~ body;
}

private string[] splitLinesCRLF(string text)
{
    string[] lines;
    size_t start;
    foreach (i; 0 .. text.length)
    {
        if (text[i] != '\r') continue;
        if (i + 1 < text.length && text[i + 1] == '\n')
        {
            lines ~= text[start .. i];
            start = i + 2;
        }
    }
    if (start < text.length) lines ~= text[start .. $];
    return lines;
}

/// Incremental decoder for Content-Length framed messages. Chunks may split
/// headers or bodies at any byte boundary.
final class LspFrameReader
{
    private string buffer;
    private size_t expected = size_t.max;

    void push(const(char)[] bytes)
    {
        buffer ~= bytes.idup;
    }

    bool pop(ref JSONValue message)
    {
        while (true)
        {
            if (expected == size_t.max)
            {
                immutable headerEnd = indexOf(buffer, "\r\n\r\n");
                if (headerEnd < 0) return false;

                size_t length;
                bool haveLength;
                foreach (line; buffer[0 .. headerEnd].splitLinesCRLF())
                {
                    immutable colon = indexOf(line, ':');
                    if (colon < 0) continue;
                    auto name = toLower(strip(line[0 .. colon]));
                    if (name == "content-length")
                    {
                        try length = strip(line[colon + 1 .. $]).to!size_t;
                        catch (Exception) return false;
                        haveLength = true;
                    }
                }
                buffer = buffer[headerEnd + 4 .. $];
                if (!haveLength || length == 0) continue;
                expected = length;
            }

            if (buffer.length < expected) return false;
            auto body = buffer[0 .. expected];
            buffer = buffer[expected .. $];
            expected = size_t.max;
            try
            {
                message = parseJSON(body);
                return true;
            }
            catch (Exception)
                continue;
        }
    }
}

private string percentDecode(string text)
{
    auto result = appender!string;
    foreach (i; 0 .. text.length)
    {
        if (text[i] == '%' && i + 2 < text.length)
        {
            try
            {
                auto decodedByte = cast(ubyte) text[i + 1 .. i + 3].to!uint(16);
                result.put(cast(char) decodedByte);
                i += 2;
                continue;
            }
            catch (Exception) { /* keep the literal percent */ }
        }
        result.put(text[i]);
    }
    return result.data;
}

/// Convert an LSP file URI into a local path. Only `file:` URIs are expected
/// from serve-d; non-file URIs are returned unchanged.
string lspURIToPath(string uri)
{
    if (!startsWith(uri, "file://")) return uri;
    auto path = percentDecode(uri[7 .. $]);
    version (Windows)
    {
        if (path.length > 2 && path[1] == ':' && path[2] == '/')
            return path[0 .. 1] ~ ":" ~ path[2 .. $];
    }
    return path;
}

/// Convert a local path into an LSP file URI.
string lspPathToURI(string path)
{
    string encoded;
    foreach (ch; path)
    {
        immutable c = cast(ubyte) ch;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || ch == '-' || ch == '_' ||
            ch == '.' || ch == '~' || ch == '/' || ch == ':' || ch == '\\')
        {
            encoded ~= ch;
            continue;
        }
        enum digits = "0123456789ABCDEF";
        encoded ~= '%';
        encoded ~= digits[(c >> 4) & 0xf];
        encoded ~= digits[c & 0xf];
    }
    version (Windows)
        return "file:///" ~ encoded;
    return "file://" ~ encoded;
}

JSONValue lspInitialize(long id, string rootURI)
{
    JSONValue[string] workspace;
    JSONValue[string] textDocument;
    JSONValue[string] capabilities;
    capabilities["workspace"] = JSONValue(workspace);
    capabilities["textDocument"] = JSONValue(textDocument);

    JSONValue[string] root;
    root["uri"] = JSONValue(rootURI);
    root["name"] = JSONValue("dcad");

    JSONValue[string] params;
    params["processId"] = JSONValue.init;
    params["rootUri"] = JSONValue(rootURI);
    params["workspaceFolders"] = JSONValue([JSONValue(root)]);
    params["capabilities"] = JSONValue(capabilities);

    JSONValue[string] message;
    message["jsonrpc"] = JSONValue("2.0");
    message["id"] = JSONValue(id);
    message["method"] = JSONValue("initialize");
    message["params"] = JSONValue(params);
    return JSONValue(message);
}

JSONValue lspNotification(string method, JSONValue params)
{
    JSONValue[string] message;
    message["jsonrpc"] = JSONValue("2.0");
    message["method"] = JSONValue(method);
    message["params"] = params;
    return JSONValue(message);
}

JSONValue lspResponse(long id, JSONValue result)
{
    JSONValue[string] message;
    message["jsonrpc"] = JSONValue("2.0");
    message["id"] = JSONValue(id);
    message["result"] = result;
    return JSONValue(message);
}

JSONValue lspInitialized()
{
    return lspNotification("initialized", JSONValue.emptyObject);
}

JSONValue lspDidOpen(string uri, string text, long documentVersion)
{
    JSONValue[string] item;
    item["uri"] = JSONValue(uri);
    item["languageId"] = JSONValue("d");
    item["version"] = JSONValue(documentVersion);
    item["text"] = JSONValue(text);

    JSONValue[string] params;
    params["textDocument"] = JSONValue(item);
    return lspNotification("textDocument/didOpen", JSONValue(params));
}

JSONValue lspDidChange(string uri, string text, long documentVersion)
{
    JSONValue[string] change;
    change["text"] = JSONValue(text);
    JSONValue[] changes = [JSONValue(change)];
    JSONValue[string] item;
    item["uri"] = JSONValue(uri);
    item["version"] = JSONValue(documentVersion);

    JSONValue[string] params;
    params["textDocument"] = JSONValue(item);
    params["contentChanges"] = JSONValue(changes);
    return lspNotification("textDocument/didChange", JSONValue(params));
}

JSONValue lspDidClose(string uri)
{
    JSONValue[string] item;
    item["uri"] = JSONValue(uri);

    JSONValue[string] params;
    params["textDocument"] = JSONValue(item);
    return lspNotification("textDocument/didClose", JSONValue(params));
}

JSONValue lspDidSave(string uri, string text)
{
    JSONValue[string] item;
    item["uri"] = JSONValue(uri);
    item["text"] = JSONValue(text);

    JSONValue[string] params;
    params["textDocument"] = JSONValue(item);
    return lspNotification("textDocument/didSave", JSONValue(params));
}

JSONValue lspCompletion(long id, string uri, LspPosition position)
{
    JSONValue[string] item;
    item["uri"] = JSONValue(uri);

    JSONValue[string] pos;
    pos["line"] = JSONValue(position.line);
    pos["character"] = JSONValue(position.character);

    JSONValue[string] params;
    params["textDocument"] = JSONValue(item);
    params["position"] = JSONValue(pos);

    JSONValue[string] message;
    message["jsonrpc"] = JSONValue("2.0");
    message["id"] = JSONValue(id);
    message["method"] = JSONValue("textDocument/completion");
    message["params"] = JSONValue(params);
    return JSONValue(message);
}

JSONValue lspShutdown(long id)
{
    JSONValue[string] message;
    message["jsonrpc"] = JSONValue("2.0");
    message["id"] = JSONValue(id);
    message["method"] = JSONValue("shutdown");
    message["params"] = JSONValue.init;
    return JSONValue(message);
}

JSONValue lspExit()
{
    return lspNotification("exit", JSONValue.init);
}

/// Decode `textDocument/publishDiagnostics` into dcad's flat shape.
LspDiagnostic[] parseLspDiagnostics(JSONValue message)
{
    LspDiagnostic[] result;
    if (agentStringField(message, "method") !=
        "textDocument/publishDiagnostics") return result;

    auto params = agentField(message, "params");
    auto path = lspURIToPath(agentStringField(params, "uri"));
    auto diagnostics = agentField(params, "diagnostics");
    if (diagnostics.type != JSONType.array) return result;

    foreach (entry; diagnostics.array)
    {
        LspDiagnostic diagnostic;
        diagnostic.path = path;
        auto range = agentField(entry, "range");
        auto start = agentField(range, "start");
        diagnostic.line = cast(long) agentUnsignedField(start, "line");
        diagnostic.character = cast(long) agentUnsignedField(start, "character");
        diagnostic.severity = cast(long) agentUnsignedField(entry, "severity");
        if (!diagnostic.severity) diagnostic.severity = 1;
        diagnostic.message = agentStringField(entry, "message");
        result ~= diagnostic;
    }
    return result;
}

/// Decode a `textDocument/completion` response. serve-d returns either an
/// array or `{ items: [...] }`.
LspCompletionItem[] parseLspCompletions(JSONValue message)
{
    LspCompletionItem[] result;
    auto items = agentField(message, "result");
    if (items.type == JSONType.object)
    {
        auto nested = agentField(items, "items");
        if (nested.type == JSONType.array) items = nested;
    }
    if (items.type != JSONType.array) return result;

    foreach (entry; items.array)
    {
        LspCompletionItem item;
        item.label = agentStringField(entry, "label");
        item.insertText = agentStringField(entry, "insertText");
        if (!item.insertText.length) item.insertText = item.label;
        item.detail = agentStringField(entry, "detail");
        if (item.label.length) result ~= item;
        if (result.length >= 64) break;
    }
    return result;
}
