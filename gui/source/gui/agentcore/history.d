/**
 * Append-only project history for the embedded agent.
 *
 * History is intentionally stored in the open project under `.dcad/` instead
 * of dcad's app cache. Credentials and transient state remain app-local.
 */
module gui.agentcore.history;

import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, append, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : File;
import std.string : strip;
import gui.agentcore.messages : AgentMessage, agentRoleName;
import gui.agentcore.paths : agentHistoryDir, agentHistoryPath;
import gui.agentcore.schema : agentField, agentStringField;

struct AgentHistoryEntry
{
    string timestamp;
    string session;
    string parent;
    string kind;
    JSONValue data;

    JSONValue toJSON(string projectRoot)
    {
        JSONValue[string] object;
        object["v"] = JSONValue(1);
        object["ts"] = JSONValue(timestamp.length
                                 ? timestamp : Clock.currTime().toISOString());
        object["project"] = JSONValue(projectRoot);
        object["session"] = JSONValue(session);
        if (parent.length) object["parent"] = JSONValue(parent);
        object["kind"] = JSONValue(kind.length ? kind : "status");

        if (data.type == JSONType.null_)
        {
            JSONValue[string] empty;
            object["data"] = JSONValue(empty);
        }
        else
            object["data"] = data;

        return JSONValue(object);
    }
}

void appendAgentHistory(string projectRoot, AgentHistoryEntry entry)
{
    mkdirRecurse(agentHistoryDir(projectRoot));
    auto file = File(agentHistoryPath(projectRoot), "a");
    file.writeln(entry.toJSON(projectRoot).toString());
}

/**
 * Mirror the legacy bridge's full transcript into project history. The
 * embedded runner appends entries incrementally instead; this keeps the two
 * paths consistent during the transition.
 */
void writeAgentHistorySnapshot(string projectRoot, string sessionId,
                               AgentMessage[] messages)
{
    mkdirRecurse(agentHistoryDir(projectRoot));
    auto path = agentHistoryPath(projectRoot);
    auto temporary = path ~ ".tmp";

    auto file = File(temporary, "w");
    foreach (message; messages)
    {
        JSONValue[string] data;
        data["role"] = JSONValue(agentRoleName(message.role));
        data["text"] = JSONValue(message.text);
        if (message.key.length) data["key"] = JSONValue(message.key);
        auto entry = AgentHistoryEntry("", sessionId, "", "message", JSONValue(data));
        file.writeln(entry.toJSON(projectRoot).toString());
    }
    file.close();

    if (exists(path)) remove(path);
    rename(temporary, path);
}

AgentHistoryEntry[] readAgentHistory(string projectRoot)
{
    AgentHistoryEntry[] result;
    auto path = agentHistoryPath(projectRoot);
    if (!exists(path)) return result;

    foreach (line; File(path, "r").byLine())
    {
        auto text = strip(line.idup);
        if (!text.length) continue;
        try
        {
            auto root = parseJSON(text);
            AgentHistoryEntry entry;
            entry.timestamp = agentStringField(root, "ts");
            entry.session = agentStringField(root, "session");
            entry.parent = agentStringField(root, "parent");
            entry.kind = agentStringField(root, "kind");
            entry.data = agentField(root, "data");
            result ~= entry;
        }
        catch (Exception)
        {
            // A truncated final line from an interrupted write is ignored.
        }
    }
    return result;
}
