/**
 * Smoke test for the GUI script host's two source forms.
 *
 * Runs a legacy body-style script, a single element module directly, and a
 * module-style assembly with animation hooks, then checks the part count.
 */
module script_host_smoke;

import std.stdio : writeln, stderr;
import std.algorithm : startsWith;
import std.algorithm.searching : canFind;
import std.file : exists, readText, mkdirRecurse, tempDir;
import std.path : baseName, buildPath;
import std.process : environment;
import std.conv : to;
import gui.agent : AgentMessage, AgentRole, agentCacheDir,
                   decodeAgentLine, makeSessionId;
import gui.platform : processId, resourceRoot;
import gui.project : Project;
import gui.script_host : ScriptHost;

int main()
{
    immutable root = resourceRoot();
    immutable workDir = buildPath(tempDir(), "dcad-script-host-smoke-"
                                  ~ processId.to!string);
    mkdirRecurse(workDir);

    // The implicit project is the sample directory, not the runtime cache, so
    // the file tree shows only project sources.
    auto bundled = Project.bundled(root);
    if (baseName(bundled.root) != "coffee-table" ||
        bundled.entry != "table.d" || !exists(bundled.entryPath()))
    {
        stderr.writeln("bundled default project is not the coffee-table sample");
        return 1;
    }

    auto host = new ScriptHost(workDir, root);

    // Legacy body-style script: the source is injected into dcad_script_run.
    auto body = host.run("Shape result = Workplane.create().box(2, 2, 2).shape;");
    if (!body.ok())
    {
        stderr.writeln("body form failed: ", body.error);
        return 1;
    }

    // One element module, opened and run directly from the project tree.
    auto element = host.run(readText(buildPath(root, "samples/coffee-table/leg.d")));
    if (!element.ok())
    {
        stderr.writeln("element module failed: ", element.error);
        return 1;
    }

    // Module-style assembly with animation hooks imported from other files.
    auto assembly = host.run(readText(buildPath(root, "gui/scripts/module-assembly.d")));
    if (!assembly.ok())
    {
        stderr.writeln("module form failed: ", assembly.error);
        return 1;
    }
    if (host.animPartCount() != 18)
    {
        stderr.writeln("module animation parts: ", host.animPartCount(),
                       " (expected 18)");
        return 1;
    }

    // File > New Project uses the same template; check it compiles and
    // exposes the three joints expected by the parts overlay.
    immutable projectDir = buildPath(workDir, "daimochi-tsugi");
    auto project = Project.create(projectDir, root);
    foreach (name; [".dcad.toml", "README.md", "main.d", "dimensions.d",
                    "daimochi_util.d", "part_a.d", "part_b.d", "key.d",
                    "motion.d"])
        if (!exists(buildPath(project.root, name)))
        {
            stderr.writeln("new project missing ", name);
            return 1;
        }

    // The TOML marker is the project root: opening the directory, the marker
    // itself, or a source file must all resolve to the same name and entry.
    foreach (candidate; [project.root,
                         buildPath(project.root, ".dcad.toml"),
                         project.entryPath])
    {
        auto opened = Project.open(candidate);
        if (opened.name != "Daimochi-tsugi" || opened.entry != "main.d")
        {
            stderr.writeln("project marker failed for ", candidate, ": ",
                           opened.name, " / ", opened.entry);
            return 1;
        }
    }

    // A distinct scratch dir avoids reusing a dylib path from the first host:
    // dlopen can hand back the old image if its dlclose was not final.
    immutable projectWorkDir = buildPath(tempDir(), "dcad-project-smoke-"
                                          ~ processId.to!string);
    mkdirRecurse(projectWorkDir);
    auto projectHost = new ScriptHost(projectWorkDir, root, project.root);
    auto joint = projectHost.run(readText(project.entryPath));
    if (!joint.ok())
    {
        stderr.writeln("new project failed: ", joint.error);
        return 1;
    }
    if (projectHost.animPartCount() != 3)
    {
        stderr.writeln("new project parts: ", projectHost.animPartCount(),
                       " (expected 3)");
        return 1;
    }

    // Agent tab: the JSON stream is decoded into a coalesced transcript, and
    // its state is kept in the app cache rather than in the project tree.
    AgentMessage[] transcript;
    string agentStatus = "idle";
    decodeAgentLine(`{"type":"text","part":{"id":"p1","text":"Hello "}}`,
                    transcript, agentStatus);
    decodeAgentLine(`{"type":"text","part":{"id":"p1","text":"world"}}`,
                    transcript, agentStatus);
    if (transcript.length != 1 ||
        transcript[0].role != AgentRole.assistant ||
        transcript[0].text != "Hello world")
    {
        stderr.writeln("agent text deltas were not coalesced");
        return 1;
    }
    decodeAgentLine(`{"type":"tool_use","part":{"tool":"read","state":` ~
                    `{"status":"completed","title":"Read file","output":"ok"}}}`,
                    transcript, agentStatus);
    if (transcript.length != 2 || transcript[1].role != AgentRole.tool ||
        transcript[1].text != "Tool Read file (completed)\nok")
    {
        stderr.writeln("agent tool event was not displayed");
        return 1;
    }
    decodeAgentLine(`{"type":"error","error":{"type":"provider.free-limit",` ~
                    `"message":"limit reached"}}`, transcript, agentStatus);
    if (transcript.length != 3 || transcript[2].role != AgentRole.error ||
        agentStatus != "Agent error")
    {
        stderr.writeln("agent error event was not displayed");
        return 1;
    }
    immutable session = makeSessionId(project.root, 42);
    if (!session.startsWith("ses") || agentCacheDir().startsWith(project.root))
    {
        stderr.writeln("agent session cache is not app-local: ", session,
                       " / ", agentCacheDir());
        return 1;
    }

    // A missing compiler must become a visible script error, not an uncaught
    // exception that makes the packaged GUI exit with status 1.
    immutable savedPath = environment.get("PATH", "");
    scope(exit) environment["PATH"] = savedPath;
    environment["PATH"] = workDir;
    auto noCompiler = host.run("Shape result = Workplane.create().box(1, 1, 1).shape;");
    if (noCompiler.ok() || noCompiler.error.length == 0 ||
        !noCompiler.error.canFind("ldc2"))
    {
        stderr.writeln("missing ldc2 was not reported: ", noCompiler.error);
        return 1;
    }

    writeln("PASS: script host forms, TOML project scaffold, daimochi joint and agent bridge");
    return 0;
}
