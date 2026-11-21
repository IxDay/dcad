/**
 * Low-level shape helpers used by the coffee-table sample.
 *
 * These are thin wrappers over the dcad shim: the reference Go sample uses
 * fluent-sdfx's rigid transforms and multi-cut/union helpers, which map to
 * gp_Trsf + BRepBuilderAPI_Transform and BRepAlgoAPI_Cut/Fuse here.
 */
module coffee_util;

import std.string : toStringz;
import dcad.shape : Shape, checkOcct;
import dcad.occt.topology : TopoDS_Shape, asShape, builtShape, dcad_shape_free;
import dcad.occt.builder : BRepBuilderAPI_MakePolygon, BRepBuilderAPI_MakeFace;
import dcad.occt.prim : BRepPrimAPI_MakePrism;
import dcad.occt.math : pnt, vec;

extern(C) nothrow @nogc
{
    int dcad_guarded_box(double dx, double dy, double dz, void** out_);
    int dcad_guarded_cut(const(void)* a, const(void)* b, void** out_);
    int dcad_guarded_fuse(const(void)* a, const(void)* b, void** out_);
    int dcad_guarded_transform(const(void)* shape, int mirrorMode, double rotZDeg,
                                double dx, double dy, double dz, void** out_);
    int dcad_make_compound(const(void)** shapes, int n, void** out_);
    int dcad_guarded_step_write(const(void)* shape, const(char)* path);
}

/// Take ownership of a freshly cloned C++ shape returned through a `void**`.
Shape fromNative(void* p)
{
    auto s = new Shape(*cast(TopoDS_Shape*) p);
    dcad_shape_free(p);
    return s;
}

/// Rigid placement. mirrorMode: 0 none, 1 flip Y (XZ plane), 2 flip X (YZ).
Shape transform(Shape s, int mirrorMode, double rotZDeg,
                double dx, double dy, double dz)
{
    void* p;
    checkOcct(dcad_guarded_transform(cast(const(void)*)&s.native(),
                                     mirrorMode, rotZDeg, dx, dy, dz, &p),
              "transform");
    return fromNative(p);
}

/// Translate by a vector.
Shape moved(Shape s, double dx, double dy, double dz)
{
    return transform(s, 0, 0, dx, dy, dz);
}

/// The same operation order as the reference `place()`: mirror across XZ,
/// rotate about Z, then translate.
Shape place(Shape s, double rotZ, double x, double y, double z, bool mirrorY)
{
    return transform(s, mirrorY ? 1 : 0, rotZ, x, y, z);
}

Shape mirrorYAbout(Shape s, double y)
{
    return transform(s, 1, 0, 0, 2 * y, 0);
}

Shape mirrorXAbout(Shape s, double x)
{
    return transform(s, 2, 0, 2 * x, 0, 0);
}

Shape cut(Shape a, Shape b)
{
    void* p;
    checkOcct(dcad_guarded_cut(cast(const(void)*)&a.native(),
                               cast(const(void)*)&b.native(), &p), "cut");
    return fromNative(p);
}

/// Sequential binary cuts. Equivalent to the reference's variadic Cut().
Shape cutAll(Shape a, Shape[] tools...)
{
    foreach (t; tools)
        a = cut(a, t);
    return a;
}

Shape fuse(Shape a, Shape b)
{
    void* p;
    checkOcct(dcad_guarded_fuse(cast(const(void)*)&a.native(),
                                cast(const(void)*)&b.native(), &p), "fuse");
    return fromNative(p);
}

Shape unionAll(Shape[] shapes...)
{
    assert(shapes.length > 0, "unionAll needs at least one shape");
    auto result = shapes[0];
    foreach (s; shapes[1 .. $])
        result = fuse(result, s);
    return result;
}

/// Extrude a closed XY polygon symmetrically about Z=0, i.e. from
/// -height/2 to +height/2. fluent-sdfx's Extrude() is centred this way,
/// which is why a wedge placed at apronZ=302 spans Z=290..314.
Shape prismXY(double[2][] points, double height)
{
    immutable baseZ = -height / 2;
    auto poly = BRepBuilderAPI_MakePolygon(0);
    foreach (p; points)
    {
        auto gp = pnt(p[0], p[1], baseZ);
        poly.Add(gp);
    }
    poly.Close();
    auto face = BRepBuilderAPI_MakeFace(poly.Wire(), false);
    auto direction = vec(0.0, 0.0, height);
    auto prism = BRepPrimAPI_MakePrism(asShape(face.Face()), direction, false, true);
    return new Shape(builtShape(prism));
}

/// Named assembly member, matching (id, name, shape) in table.py's parts().
struct NamedPart
{
    string id;
    string name;
    Shape shape;
}

/// Package every part into one compound (no boolean unification).
Shape compound(Shape[] shapes...)
{
    const(void)*[] ptrs;
    ptrs.reserve(shapes.length);
    foreach (s; shapes)
        ptrs ~= cast(const(void)*)&s.native();
    void* p;
    checkOcct(dcad_make_compound(ptrs.ptr, cast(int) ptrs.length, &p), "compound");
    return fromNative(p);
}

void exportStep(Shape s, string path)
{
    checkOcct(dcad_guarded_step_write(cast(const(void)*)&s.native(),
                                      path.toStringz), "STEP export");
}
