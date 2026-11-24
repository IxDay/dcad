/**
 * Smoke test for the GUI script host's two source forms.
 *
 * Runs a legacy body-style script, a single element module directly, and a
 * module-style assembly with animation hooks, then checks the part count.
 */
module script_host_smoke;

import std.stdio : writeln, stderr;
import std.file : readText, mkdirRecurse, getcwd, tempDir;
import std.path : buildPath;
import std.conv : to;
import gui.platform : processId;

import gui.script_host : ScriptHost;

int main()
{
    immutable root = getcwd();
    immutable workDir = buildPath(tempDir(), "dcad-script-host-smoke-"
                                  ~ processId.to!string);
    mkdirRecurse(workDir);
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

    writeln("PASS: script host body form, element module and module assembly");
    return 0;
}
