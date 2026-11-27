/**
 * Built-in project tools for the embedded agent. Every file tool resolves
 * paths lexically inside the project root; shell execution runs in that root
 * and is gated by the permission engine in the runner.
 */
module gui.agentcore.tools;

import std.algorithm : sort, startsWith;
import std.conv : to;
import std.file : dirEntries, exists, isDir, mkdirRecurse, readText, write, SpanMode;
import std.json : JSONType, JSONValue;
import std.path : absolutePath, buildPath, dirName;
import std.process : Config, executeShell;
import std.regex : matchFirst, regex;
import std.string : indexOf, join, splitLines, strip;
import gui.agentcore.events : AgentEvent;
import gui.agentcore.patches : AgentChangeRecorder;
import gui.agentcore.permissions : agentWildcardMatch;
import gui.agentcore.schema : agentField, agentStringField, agentUnsignedField;

version (Windows) private enum pathSep = "\\";
else private enum pathSep = "/";

alias AgentSubagentRunner = string delegate(string prompt, string activeFile,
                                            scope void delegate(AgentEvent) emit,
                                            scope bool delegate() cancelled);

interface AgentTool
{
    string name();
    string description();
    JSONValue inputSchema();
    JSONValue execute(JSONValue input, string projectRoot,
                      bool delegate() cancelled,
                      AgentChangeRecorder recorder = null);
}

private JSONValue textResult(string text, bool isError = false)
{
    JSONValue[string] content;
    content["type"] = JSONValue("text");
    content["text"] = JSONValue(text);
    JSONValue[] contents = [JSONValue(content)];

    JSONValue[string] result;
    result["content"] = JSONValue(contents);
    if (isError) result["isError"] = JSONValue(true);
    return JSONValue(result);
}

private bool wasCancelled(bool delegate() cancelled)
{
    return cancelled !is null && cancelled();
}

private string pathField(JSONValue input)
{
    auto path = agentStringField(input, "file");
    if (!path.length) path = agentStringField(input, "path");
    return path;
}

private string resolveProjectPath(string projectRoot, string path)
{
    if (!path.length) throw new Exception("missing path");
    auto root = absolutePath(projectRoot);
    while (root.length > 1 && root[$ - 1] == pathSep[0]) root = root[0 .. $ - 1];
    auto resolved = absolutePath(buildPath(root, path));
    auto prefix = root ~ pathSep;
    if (resolved != root && !resolved.startsWith(prefix))
        throw new Exception("path outside project: " ~ path);
    return resolved;
}

private string relativeName(string root, string path)
{
    auto prefix = root ~ pathSep;
    return path.startsWith(prefix) ? path[prefix.length .. $] : path;
}

private bool isHiddenAgentDir(string path)
{
    import std.path : baseName;
    return baseName(path) == ".dcad";
}

private JSONValue simpleSchema(string property, string description)
{
    JSONValue[string] properties;
    JSONValue[string] field;
    field["type"] = JSONValue("string");
    field["description"] = JSONValue(description);
    properties[property] = JSONValue(field);

    JSONValue[string] schema;
    schema["type"] = JSONValue("object");
    schema["properties"] = JSONValue(properties);
    schema["required"] = JSONValue([JSONValue(property)]);
    return JSONValue(schema);
}

private final class AgentReadTool : AgentTool
{
    string name() { return "read"; }
    string description() { return "Read a text file in the project"; }
    JSONValue inputSchema() { return simpleSchema("file", "Project-relative file path"); }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        try
        {
            auto path = resolveProjectPath(projectRoot, pathField(input));
            if (!exists(path)) return textResult("file not found", true);
            return textResult(readText(path));
        }
        catch (Exception e) return textResult(e.msg, true);
    }
}

private final class AgentWriteTool : AgentTool
{
    string name() { return "write"; }
    string description() { return "Write a text file in the project"; }
    JSONValue inputSchema()
    {
        JSONValue[string] properties;
        JSONValue[string] file;
        file["type"] = JSONValue("string");
        properties["file"] = JSONValue(file);
        JSONValue[string] content;
        content["type"] = JSONValue("string");
        properties["content"] = JSONValue(content);

        JSONValue[string] schema;
        schema["type"] = JSONValue("object");
        schema["properties"] = JSONValue(properties);
        return JSONValue(schema);
    }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        try
        {
            auto path = resolveProjectPath(projectRoot, pathField(input));
            if (recorder !is null)
                recorder.capture(relativeName(absolutePath(projectRoot), path));
            mkdirRecurse(dirName(path));
            write(path, agentStringField(input, "content"));
            return textResult("wrote " ~ relativeName(absolutePath(projectRoot), path));
        }
        catch (Exception e) return textResult(e.msg, true);
    }
}

private final class AgentEditTool : AgentTool
{
    string name() { return "edit"; }
    string description() { return "Replace exact text in a project file"; }
    JSONValue inputSchema()
    {
        return (new AgentWriteTool).inputSchema();
    }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        try
        {
            auto path = resolveProjectPath(projectRoot, pathField(input));
            if (recorder !is null)
                recorder.capture(relativeName(absolutePath(projectRoot), path));
            auto text = readText(path);
            auto oldText = agentStringField(input, "oldString");
            auto newText = agentStringField(input, "newString");
            auto at = text.indexOf(oldText);
            if (at < 0) return textResult("oldString not found", true);
            text = text[0 .. at] ~ newText ~ text[at + oldText.length .. $];
            write(path, text);
            return textResult("edited " ~ relativeName(absolutePath(projectRoot), path));
        }
        catch (Exception e) return textResult(e.msg, true);
    }
}

private final class AgentGlobTool : AgentTool
{
    string name() { return "glob"; }
    string description() { return "Find project files matching a wildcard"; }
    JSONValue inputSchema() { return simpleSchema("pattern", "Wildcard such as *.d"); }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        try
        {
            auto root = absolutePath(projectRoot);
            auto pattern = agentStringField(input, "pattern", "*");
            string[] matches;
            foreach (entry; dirEntries(root, SpanMode.depth))
            {
                if (cancelled !is null && cancelled()) return textResult("cancelled", true);
                if (isHiddenAgentDir(entry.name)) continue;
                if (entry.isDir) continue;
                auto relative = relativeName(root, entry.name);
                if (agentWildcardMatch(pattern, relative) ||
                    agentWildcardMatch("**/" ~ pattern, relative))
                    matches ~= relative;
                if (matches.length >= 200) break;
            }
            sort(matches);
            return textResult(matches.length ? matches.join("\n") : "no matches");
        }
        catch (Exception e) return textResult(e.msg, true);
    }
}

private final class AgentGrepTool : AgentTool
{
    string name() { return "grep"; }
    string description() { return "Search project text files with a regex"; }
    JSONValue inputSchema() { return simpleSchema("pattern", "Regular expression"); }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        try
        {
            auto root = absolutePath(projectRoot);
            auto expression = regex(agentStringField(input, "pattern"));
            auto limit = agentUnsignedField(input, "maxResults");
            if (!limit) limit = 100;

            string[] matches;
            foreach (entry; dirEntries(root, SpanMode.depth))
            {
                if (cancelled !is null && cancelled()) return textResult("cancelled", true);
                if (isHiddenAgentDir(entry.name) || entry.isDir) continue;
                auto relative = relativeName(root, entry.name);
                foreach (lineNumber, line; readText(entry.name).splitLines())
                {
                    if (matchFirst(line, expression))
                    {
                        import std.conv : to;
                        matches ~= relative ~ ":" ~ (lineNumber + 1).to!string ~ ":" ~ line;
                        if (matches.length >= limit) break;
                    }
                }
                if (matches.length >= limit) break;
            }
            return textResult(matches.length ? matches.join("\n") : "no matches");
        }
        catch (Exception e) return textResult(e.msg, true);
    }
}

private final class AgentShellTool : AgentTool
{
    string name() { return "shell"; }
    string description() { return "Run a shell command in the project root"; }
    JSONValue inputSchema() { return simpleSchema("command", "Command line"); }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        auto command = agentStringField(input, "command");
        if (!command.length) return textResult("missing command", true);
        try
        {
            if (recorder !is null) recorder.captureAll();
            auto result = executeShell(command, null, Config.none, size_t.max,
                                       projectRoot);
            if (recorder !is null) recorder.captureMissing();
            auto text = result.output.length ? result.output : "exit " ~ result.status.to!string;
            return textResult(text, result.status != 0);
        }
        catch (Exception e) return textResult(e.msg, true);
    }
}

private final class AgentSubagentTool : AgentTool
{
    private AgentSubagentRunner runner;

    this(AgentSubagentRunner runner)
    {
        this.runner = runner;
    }

    string name() { return "subagent"; }
    string description()
    {
        return "Run a focused task in a child session and return its answer";
    }

    JSONValue inputSchema()
    {
        JSONValue[string] properties;
        JSONValue[string] prompt;
        prompt["type"] = JSONValue("string");
        prompt["description"] = JSONValue("Task for the child agent");
        properties["prompt"] = JSONValue(prompt);
        JSONValue[string] description;
        description["type"] = JSONValue("string");
        properties["description"] = JSONValue(description);

        JSONValue[string] schema;
        schema["type"] = JSONValue("object");
        schema["properties"] = JSONValue(properties);
        schema["required"] = JSONValue([JSONValue("prompt")]);
        return JSONValue(schema);
    }

    JSONValue execute(JSONValue input, string projectRoot, bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (wasCancelled(cancelled)) return textResult("cancelled", true);
        auto prompt = agentStringField(input, "prompt");
        if (!prompt.length) prompt = agentStringField(input, "description");
        if (!prompt.length) return textResult("missing prompt", true);
        if (runner is null) return textResult("subagent is unavailable", true);

        auto label = agentStringField(input, "description", "subagent");
        return textResult("Task: " ~ label ~ "\n" ~ runner(prompt, "", null, cancelled));
    }
}

final class AgentToolRegistry
{
    private AgentTool[string] tools;

    this(AgentSubagentRunner subagentRunner = null)
    {
        register(new AgentReadTool);
        register(new AgentWriteTool);
        register(new AgentEditTool);
        register(new AgentGlobTool);
        register(new AgentGrepTool);
        register(new AgentShellTool);
        register(new AgentSubagentTool(subagentRunner));
    }

    void register(AgentTool tool)
    {
        tools[tool.name] = tool;
    }

    AgentTool find(string name)
    {
        if (auto found = name in tools) return *found;
        return null;
    }

    JSONValue[] toolSchemas()
    {
        auto names = tools.keys;
        sort(names);
        JSONValue[] result;
        foreach (name; names)
        {
            auto tool = tools[name];
            JSONValue[string] entry;
            entry["name"] = JSONValue(tool.name);
            entry["description"] = JSONValue(tool.description);
            entry["parameters"] = tool.inputSchema();
            result ~= JSONValue(entry);
        }
        return result;
    }

    JSONValue execute(string name, JSONValue input, string projectRoot,
                      bool delegate() cancelled,
                      AgentChangeRecorder recorder = null)
    {
        if (auto tool = find(name))
            return tool.execute(input, projectRoot, cancelled, recorder);
        return textResult("unknown tool: " ~ name, true);
    }
}
