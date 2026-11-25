/**
 * Shape helpers for this project.
 *
 * These are deliberately thin: a block is an OCCT box translated by a
 * gp_Trsf, and a part is the sequential fuse of its blocks. Keeping the helper
 * local makes the geometry files read as data, not as kernel plumbing.
 */
module daimochi_util;

import std.string : toStringz;
import dcad.shape : Shape, checkOcct;
import dcad.occt.topology : TopoDS_Shape, dcad_shape_free;

extern(C) nothrow @nogc
{
    int dcad_guarded_box(double dx, double dy, double dz, void** out_);
    int dcad_guarded_fuse(const(void)* a, const(void)* b, void** out_);
    int dcad_guarded_transform(const(void)* shape, int mirrorMode,
                               double rotZDeg, double dx, double dy, double dz,
                               void** out_);
    int dcad_make_compound(const(void)** shapes, int n, void** out_);
}

private Shape fromNative(void* p)
{
    auto shape = new Shape(*cast(TopoDS_Shape*) p);
    dcad_shape_free(p);
    return shape;
}

/// A box from two opposite corners, both in millimetres.
Shape block(double x0, double y0, double z0,
            double x1, double y1, double z1)
{
    immutable dx = x1 - x0;
    immutable dy = y1 - y0;
    immutable dz = z1 - z0;
    assert(dx > 0 && dy > 0 && dz > 0, "block corners are reversed");

    void* boxed;
    checkOcct(dcad_guarded_box(dx, dy, dz, &boxed), "box");
    auto result = fromNative(boxed);

    void* placed;
    checkOcct(dcad_guarded_transform(cast(const(void)*)&result.native(),
                                     0, 0, x0, y0, z0, &placed), "translate");
    return fromNative(placed);
}

/// Translate a finished part; used for the exploded keyframes.
Shape moved(Shape shape, double dx, double dy, double dz)
{
    void* placed;
    checkOcct(dcad_guarded_transform(cast(const(void)*)&shape.native(),
                                     0, 0, dx, dy, dz, &placed), "translate");
    return fromNative(placed);
}

/// Fuse blocks into one solid. The blocks may touch or overlap.
Shape unionAll(Shape[] shapes...)
{
    assert(shapes.length > 0, "unionAll needs at least one block");
    auto result = shapes[0];
    foreach (shape; shapes[1 .. $])
    {
        void* fused;
        checkOcct(dcad_guarded_fuse(cast(const(void)*)&result.native(),
                                    cast(const(void)*)&shape.native(), &fused),
                  "fuse");
        result = fromNative(fused);
    }
    return result;
}

/// An assembly is a compound: the pieces keep their own identity in the
/// preview's parts list instead of being merged into one solid.
Shape compound(Shape[] shapes...)
{
    const(void)*[] ptrs;
    foreach (shape; shapes)
        ptrs ~= cast(const(void)*)&shape.native();
    void* result;
    checkOcct(dcad_make_compound(ptrs.ptr, cast(int) ptrs.length, &result),
              "compound");
    return fromNative(result);
}

/// The animation protocol uses these three fields.
struct NamedPart
{
    string id;
    string name;
    Shape shape;
}
