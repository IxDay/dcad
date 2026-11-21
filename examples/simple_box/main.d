/** Minimal acceptance example: a box, directly exported to STEP. */
import std.stdio;
import dcad.dsl.workplane : Workplane;

void main()
{
    auto box = Workplane.create().box(10, 20, 30);
    writefln("box volume: %.3f mm^3", box.shape.volume());
    box.exportStep("simple_box.step");
    writeln("wrote simple_box.step");
}
