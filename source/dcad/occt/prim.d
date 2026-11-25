/**
 * Solid primitives and extrusion: direct extern(C++) declarations of the
 * OCCT BRepPrimAPI subset.
 */
module dcad.occt.prim;

import dcad.occt.types : opaqueWords, cxxMangle;
import dcad.occt.math : gp_Pnt, gp_Vec, gp_Ax2, Message_ProgressRange;
import dcad.occt.topology : TopoDS_Shape;

extern(C++) struct BRepPrimAPI_MakeBox
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN19BRepPrimAPI_MakeBoxC1Eddd",
        "??0BRepPrimAPI_MakeBox@@QEAA@NNN@Z")) this(double dx, double dy, double dz);

    pragma(mangle, cxxMangle!(
        "_ZN19BRepPrimAPI_MakeBoxC1ERK6gp_Pntddd",
        "??0BRepPrimAPI_MakeBox@@QEAA@AEBVgp_Pnt@@NNN@Z")) this(ref const gp_Pnt origin, double dx, double dy, double dz);

    pragma(mangle, cxxMangle!(
        "_ZN19BRepPrimAPI_MakeBoxC1ERK6gp_PntS2_",
        "??0BRepPrimAPI_MakeBox@@QEAA@AEBVgp_Pnt@@0@Z")) this(ref const gp_Pnt p1, ref const gp_Pnt p2);

    pragma(mangle, cxxMangle!(
        "_ZN19BRepPrimAPI_MakeBoxC1ERK6gp_Ax2ddd",
        "??0BRepPrimAPI_MakeBox@@QEAA@AEBVgp_Ax2@@NNN@Z")) this(ref const gp_Ax2 axes, double dx, double dy, double dz);
}

extern(C++) struct BRepPrimAPI_MakeCylinder
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN24BRepPrimAPI_MakeCylinderC1Edd",
        "??0BRepPrimAPI_MakeCylinder@@QEAA@NN@Z")) this(double radius, double height);

    pragma(mangle, cxxMangle!(
        "_ZN24BRepPrimAPI_MakeCylinderC1Eddd",
        "??0BRepPrimAPI_MakeCylinder@@QEAA@NNN@Z")) this(double radius, double height, double angle);

    pragma(mangle, cxxMangle!(
        "_ZN24BRepPrimAPI_MakeCylinderC1ERK6gp_Ax2dd",
        "??0BRepPrimAPI_MakeCylinder@@QEAA@AEBVgp_Ax2@@NN@Z")) this(ref const gp_Ax2 axes, double radius, double height);
}

extern(C++) struct BRepPrimAPI_MakePrism
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN21BRepPrimAPI_MakePrismC1ERK12TopoDS_ShapeRK6gp_Vecbb",
        "??0BRepPrimAPI_MakePrism@@QEAA@AEBVTopoDS_Shape@@AEBVgp_Vec@@_N2@Z")) this(ref const TopoDS_Shape profile, ref const gp_Vec vector,
        bool copy, bool canonize);
}
