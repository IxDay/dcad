/**
 * Coffee table -- D/OCCT port of ../cadquery/samples/coffee-table.
 *
 * A 1400 x 600 x 362 mm knock-down timber table: four notched legs, two long
 * aprons, two end aprons with wedged through-tenons, two cross rails, four
 * grooved top planks and four wedges. Every timber is exported as its own
 * exact B-rep STEP file; a compound STEP holds the whole assembly.
 *
 * Run with:  dub run :coffee-table
 */
import std.stdio;
import std.file : mkdirRecurse;
import std.math : abs;
import dcad.shape : Shape;
import coffee_util : NamedPart, compound, exportStep;
import coffee_parts : tableParts;
import coffee_motion : writeAnimation;

void main()
{
    auto parts = tableParts();
    mkdirRecurse("table");

    foreach (p; parts)
    {
        exportStep(p.shape, "table/" ~ p.id ~ ".step");
        immutable b = p.shape.bounds();
        writefln("%-20s vol=%10.2f  x=[%7.2f,%7.2f] y=[%7.2f,%7.2f] z=[%6.2f,%6.2f]",
                 p.id, p.shape.volume(), b[0], b[3], b[1], b[4], b[2], b[5]);
    }

    Shape[] shapes;
    foreach (p; parts)
        shapes ~= p.shape;
    auto assembly = compound(shapes);
    exportStep(assembly, "coffee-table.step");

    immutable b = assembly.bounds();
    writefln("assembly: %d parts, %.1f x %.1f x %.1f mm, volume %.2f mm^3",
             parts.length, b[3] - b[0], b[4] - b[1], b[5] - b[2],
             assembly.volume());
    assert(parts.length == 18);
    assert(abs((b[3] - b[0]) - 1400.0) < 0.01);
    assert(abs((b[4] - b[1]) - 600.0) < 0.01);
    assert(abs((b[5] - b[2]) - 362.0) < 0.01);

    writeAnimation("table/animation.json");
    writeln("wrote table/*.step, coffee-table.step and table/animation.json");
}
