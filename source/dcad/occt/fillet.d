/**
 * Fillet and chamfer (BRepFilletAPI subset). Both operate on EDGES, never on
 * faces -- this is the single most common CadQuery-porting surprise.
 */
module dcad.occt.fillet;

import dcad.occt.types : opaqueWords, ChFi3d_FilletShape;
import dcad.occt.topology : TopoDS_Shape, TopoDS_Edge;

extern(C++) struct BRepFilletAPI_MakeFillet
{
    void*[opaqueWords] _opaque;

    this(ref const TopoDS_Shape shape, ChFi3d_FilletShape style);

    void Add(double radius, ref const TopoDS_Edge edge);
}

extern(C++) struct BRepFilletAPI_MakeChamfer
{
    void*[opaqueWords] _opaque;

    this(ref const TopoDS_Shape shape);

    void Add(double distance, ref const TopoDS_Edge edge);
}
