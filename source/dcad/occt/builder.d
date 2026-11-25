/**
 * Sketch/wire/face construction (BRepBuilderAPI subset).
 */
module dcad.occt.builder;

import dcad.occt.types : opaqueWords, cxxMangle;
import dcad.occt.math : gp_Pnt;
import dcad.occt.topology : TopoDS_Edge, TopoDS_Wire, TopoDS_Face, TopoDS_Shape;

extern(C++) struct BRepBuilderAPI_MakePolygon
{
    void*[opaqueWords] _opaque;

    // A D struct cannot declare a zero-argument ctor; an explicit mangle pins
    // the C++ default constructor while a dummy parameter keeps D happy.
    pragma(mangle, cxxMangle!(
        "_ZN26BRepBuilderAPI_MakePolygonC1Ev",
        "??0BRepBuilderAPI_MakePolygon@@QEAA@XZ")) this(int dummy);

    pragma(mangle, cxxMangle!(
        "_ZN26BRepBuilderAPI_MakePolygon3AddERK6gp_Pnt",
        "?Add@BRepBuilderAPI_MakePolygon@@QEAAXAEBVgp_Pnt@@@Z")) void Add(ref const gp_Pnt p);

    pragma(mangle, cxxMangle!(
        "_ZN26BRepBuilderAPI_MakePolygon5CloseEv",
        "?Close@BRepBuilderAPI_MakePolygon@@QEAAXXZ")) void Close();

    pragma(mangle, cxxMangle!(
        "_ZN26BRepBuilderAPI_MakePolygon4WireEv",
        "?Wire@BRepBuilderAPI_MakePolygon@@QEAAAEBVTopoDS_Wire@@XZ")) ref const(TopoDS_Wire) Wire();
}

extern(C++) struct BRepBuilderAPI_MakeWire
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeWireC1Ev",
        "??0BRepBuilderAPI_MakeWire@@QEAA@XZ")) this(int dummy);

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeWireC1ERK11TopoDS_Edge",
        "??0BRepBuilderAPI_MakeWire@@QEAA@AEBVTopoDS_Edge@@@Z")) this(ref const TopoDS_Edge edge);

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeWire3AddERK11TopoDS_Edge",
        "?Add@BRepBuilderAPI_MakeWire@@QEAAXAEBVTopoDS_Edge@@@Z")) void Add(ref const TopoDS_Edge edge);

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeWire3AddERK11TopoDS_Wire",
        "?Add@BRepBuilderAPI_MakeWire@@QEAAXAEBVTopoDS_Wire@@@Z")) void Add(ref const TopoDS_Wire wire);

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeWire4WireEv",
        "?Wire@BRepBuilderAPI_MakeWire@@QEAAAEBVTopoDS_Wire@@XZ")) ref const(TopoDS_Wire) Wire();
}

extern(C++) struct BRepBuilderAPI_MakeFace
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeFaceC1ERK11TopoDS_Wireb",
        "??0BRepBuilderAPI_MakeFace@@QEAA@AEBVTopoDS_Wire@@_N@Z")) this(ref const TopoDS_Wire wire, bool onlyPlane);

    pragma(mangle, cxxMangle!(
        "_ZNK23BRepBuilderAPI_MakeFace4FaceEv",
        "?Face@BRepBuilderAPI_MakeFace@@QEBAAEBVTopoDS_Face@@XZ")) ref const(TopoDS_Face) Face() const;
}

extern(C++) struct BRepBuilderAPI_MakeEdge
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeEdgeC1ERK6gp_PntS2_",
        "??0BRepBuilderAPI_MakeEdge@@QEAA@AEBVgp_Pnt@@0@Z")) this(ref const gp_Pnt p1, ref const gp_Pnt p2);

    pragma(mangle, cxxMangle!(
        "_ZN23BRepBuilderAPI_MakeEdge4EdgeEv",
        "?Edge@BRepBuilderAPI_MakeEdge@@QEAAAEBVTopoDS_Edge@@XZ")) ref const(TopoDS_Edge) Edge();
}
