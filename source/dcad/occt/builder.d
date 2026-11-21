/**
 * Sketch/wire/face construction (BRepBuilderAPI subset).
 */
module dcad.occt.builder;

import dcad.occt.types : opaqueWords;
import dcad.occt.math : gp_Pnt;
import dcad.occt.topology : TopoDS_Edge, TopoDS_Wire, TopoDS_Face, TopoDS_Shape;

extern(C++) struct BRepBuilderAPI_MakePolygon
{
    void*[opaqueWords] _opaque;

    // A D struct cannot declare a zero-argument ctor; pragma(mangle) pins the
    // C++ default constructor while a dummy parameter keeps D happy.
    pragma(mangle, "_ZN26BRepBuilderAPI_MakePolygonC1Ev") this(int dummy);

    void Add(ref const gp_Pnt p);
    void Close();
    ref const(TopoDS_Wire) Wire();
}

extern(C++) struct BRepBuilderAPI_MakeWire
{
    void*[opaqueWords] _opaque;

    pragma(mangle, "_ZN23BRepBuilderAPI_MakeWireC1Ev") this(int dummy);
    this(ref const TopoDS_Edge edge);

    void Add(ref const TopoDS_Edge edge);
    void Add(ref const TopoDS_Wire wire);
    ref const(TopoDS_Wire) Wire();
}

extern(C++) struct BRepBuilderAPI_MakeFace
{
    void*[opaqueWords] _opaque;

    this(ref const TopoDS_Wire wire, bool onlyPlane);

    ref const(TopoDS_Face) Face() const;
}

extern(C++) struct BRepBuilderAPI_MakeEdge
{
    void*[opaqueWords] _opaque;

    this(ref const gp_Pnt p1, ref const gp_Pnt p2);

    ref const(TopoDS_Edge) Edge();
}
