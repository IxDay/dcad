/**
 * Fillet and chamfer (BRepFilletAPI subset). Both operate on EDGES, never on
 * faces -- this is the single most common CadQuery-porting surprise.
 */
module dcad.occt.fillet;

import dcad.occt.types : opaqueWords, ChFi3d_FilletShape, cxxMangle;
import dcad.occt.topology : TopoDS_Shape, TopoDS_Edge;

extern(C++) struct BRepFilletAPI_MakeFillet
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN24BRepFilletAPI_MakeFilletC1ERK12TopoDS_Shape18ChFi3d_FilletShape",
        "??0BRepFilletAPI_MakeFillet@@QEAA@AEBVTopoDS_Shape@@W4ChFi3d_FilletShape@@@Z")) this(ref const TopoDS_Shape shape, ChFi3d_FilletShape style);

    pragma(mangle, cxxMangle!(
        "_ZN24BRepFilletAPI_MakeFillet3AddEdRK11TopoDS_Edge",
        "?Add@BRepFilletAPI_MakeFillet@@QEAAXNAEBVTopoDS_Edge@@@Z")) void Add(double radius, ref const TopoDS_Edge edge);
}

extern(C++) struct BRepFilletAPI_MakeChamfer
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN25BRepFilletAPI_MakeChamferC1ERK12TopoDS_Shape",
        "??0BRepFilletAPI_MakeChamfer@@QEAA@AEBVTopoDS_Shape@@@Z")) this(ref const TopoDS_Shape shape);

    pragma(mangle, cxxMangle!(
        "_ZN25BRepFilletAPI_MakeChamfer3AddEdRK11TopoDS_Edge",
        "?Add@BRepFilletAPI_MakeChamfer@@QEAAXNAEBVTopoDS_Edge@@@Z")) void Add(double distance, ref const TopoDS_Edge edge);
}
