/**
 * Phase 2 acceptance example: loft two rectangular wires into a solid.
 * Mirrors CadQuery's .workplane().rect().workplane(offset=...).rect().loft().
 */
import std.stdio;
import dcad.shape : Shape, checkOcct;
import dcad.occt.topology : TopoDS_Wire, builtShape, asShape;
import dcad.occt.loft : BRepOffsetAPI_ThruSections;
import dcad.occt.builder : BRepBuilderAPI_MakePolygon;
import dcad.occt.math : pnt;

extern(C) nothrow @nogc
{
    int dcad_guarded_step_write(const(void)* shape, const(char)* path);
}

Shape rectWire(double halfX, double halfY, double z)
{
    auto poly = BRepBuilderAPI_MakePolygon(0);
    foreach (p; [[-halfX, -halfY], [halfX, -halfY], [halfX, halfY], [-halfX, halfY]])
    {
        auto gp = pnt(p[0], p[1], z);
        poly.Add(gp);
    }
    poly.Close();
    return new Shape(asShape(poly.Wire()));
}

void main()
{
    auto lower = rectWire(20, 20, 0);
    auto upper = rectWire(8, 12, 30);

    auto loft = BRepOffsetAPI_ThruSections(true, false, 1e-6);
    loft.AddWire(*cast(const(TopoDS_Wire)*)&lower.native());
    loft.AddWire(*cast(const(TopoDS_Wire)*)&upper.native());
    auto result = new Shape(builtShape(loft));

    writefln("loft volume: %.3f mm^3", result.volume());
    checkOcct(dcad_guarded_step_write(cast(const(void)*)&result.native(),
                                      "loft.step"), "STEP export");
    writeln("wrote loft.step");
}
