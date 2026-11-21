/**
 * Proof of concept: box -> top-face sketch -> through hole -> fillet -> STEP.
 *
 * Run with:  dub run :box-hole-fillet
 */
import std.stdio;
import dcad.dsl.workplane : Workplane;
import dcad.dsl.selector : FaceSelector, EdgeSelector;

void main()
{
    auto model = Workplane.create()
        .box(80.0, 60.0, 10.0)
        .faces(FaceSelector.top)
        .circle(8.0)
        .cutThruAll()
        .edges(EdgeSelector.vertical)
        .fillet(2.0);

    const b = model.shape.bounds();
    writefln("bounds: [%.3f %.3f %.3f] .. [%.3f %.3f %.3f]",
             b[0], b[1], b[2], b[3], b[4], b[5]);
    writefln("volume: %.3f mm^3", model.shape.volume());

    model.exportStep("box_hole_fillet.step");
    writeln("wrote box_hole_fillet.step");
}
