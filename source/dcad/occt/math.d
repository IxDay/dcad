/**
 * gp_* value types.
 *
 * gp_Pnt/gp_Vec/gp_Dir/gp_XYZ are tiny, non-polymorphic value classes whose
 * C++ methods are all inline (no out-of-line symbols to link against). Their
 * C++ layouts are exactly three doubles, so we mirror those layouts in D and
 * implement the accessors in D. That keeps them ABI-compatible as `const T&`
 * arguments to the rest of the bindings.
 */
module dcad.occt.math;

import dcad.occt.types : opaqueWords;

extern(C++) struct gp_XYZ
{
    double x, y, z;
}

extern(C++) struct gp_Pnt
{
    gp_XYZ coord;
}

extern(C++) struct gp_Vec
{
    gp_XYZ coord;
}

extern(C++) struct gp_Dir
{
    gp_XYZ coord;
}

/// Construct a gp_Pnt without calling an inline C++ constructor.
gp_Pnt pnt(double x, double y, double z) @safe pure nothrow
{
    gp_Pnt p;
    p.coord = gp_XYZ(x, y, z);
    return p;
}

gp_Vec vec(double x, double y, double z) @safe pure nothrow
{
    gp_Vec v;
    v.coord = gp_XYZ(x, y, z);
    return v;
}

/// Mirrors gp_Dir's invariant: a normalized vector. Throws if the norm is 0.
gp_Dir dir(double x, double y, double z)
{
    import std.math : sqrt;
    import std.exception : enforce;

    const n = sqrt(x * x + y * y + z * z);
    enforce(n > 1e-12, "gp_Dir: zero norm");
    gp_Dir d;
    d.coord = gp_XYZ(x / n, y / n, z / n);
    return d;
}

/// A coordinate frame. The C++ constructor is out-of-line (Standard_EXPORT).
extern(C++) struct gp_Ax2
{
    void*[opaqueWords] _opaque;

    this(ref const gp_Pnt origin, ref const gp_Dir normal);
}

/// Returned by value from gp_* accessors; here we only need its identity.
extern(C++) struct gp_Ax1
{
    void*[opaqueWords] _opaque;
    this(ref const gp_Pnt origin, ref const gp_Dir direction);
}

/// Transformation matrix. Bound for completeness; built by C++ methods.
extern(C++) struct gp_Trsf
{
    void*[opaqueWords] _opaque;
}

/// An empty progress range: the default argument of OCCT's builder ctors.
extern(C++) struct Message_ProgressRange
{
    void*[opaqueWords] _opaque;
}
