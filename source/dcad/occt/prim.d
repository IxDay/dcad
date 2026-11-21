/**
 * Solid primitives and extrusion: direct extern(C++) declarations of the
 * OCCT BRepPrimAPI subset.
 */
module dcad.occt.prim;

import dcad.occt.types : opaqueWords;
import dcad.occt.math : gp_Pnt, gp_Vec, gp_Ax2, Message_ProgressRange;
import dcad.occt.topology : TopoDS_Shape;

extern(C++) struct BRepPrimAPI_MakeBox
{
    void*[opaqueWords] _opaque;

    this(double dx, double dy, double dz);
    this(ref const gp_Pnt origin, double dx, double dy, double dz);
    this(ref const gp_Pnt p1, ref const gp_Pnt p2);
    this(ref const gp_Ax2 axes, double dx, double dy, double dz);
}

extern(C++) struct BRepPrimAPI_MakeCylinder
{
    void*[opaqueWords] _opaque;

    this(double radius, double height);
    this(double radius, double height, double angle);
    this(ref const gp_Ax2 axes, double radius, double height);
}

extern(C++) struct BRepPrimAPI_MakePrism
{
    void*[opaqueWords] _opaque;

    this(ref const TopoDS_Shape profile, ref const gp_Vec vector,
         bool copy, bool canonize);
}
