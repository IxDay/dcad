/**
 * Smoke test for the GUI script host's two source forms.
 *
 * Runs a legacy body-style script, a single element module directly, and a
 * module-style assembly with animation hooks, then checks the part count.
 */
module script_host_smoke;

import std.stdio : writeln, stderr;
import std.file : exists, readText, mkdirRecurse, tempDir;
import std.path : buildPath;
import std.conv : to;
import gui.platform : processId, resourceRoot;
import gui.project : Project;
import gui.script_host : ScriptHost;

int main()
{
    immutable root = resourceRoot();
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

    // File > New Project uses the same template; check it compiles and
    // exposes the three joints expected by the parts overlay.
    immutable projectDir = buildPath(workDir, "daimochi-tsugi");
    auto project = Project.create(projectDir, root);
    foreach (name; ["dcad.json", "README.md", "main.d", "dimensions.d",
                    "daimochi_util.d", "part_a.d", "part_b.d", "key.d",
                    "motion.d"])
        if (!exists(buildPath(project.root, name)))
        {
            stderr.writeln("new project missing ", name);
            return 1;
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

    writeln("PASS: script host forms, new project scaffold and daimochi joint");
    return 0;
}
