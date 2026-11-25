/**
 * Loft through a set of wires (BRepOffsetAPI subset).
 */
module dcad.occt.loft;

import dcad.occt.types : opaqueWords, cxxMangle;
import dcad.occt.topology : TopoDS_Wire;

extern(C++) struct BRepOffsetAPI_ThruSections
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN26BRepOffsetAPI_ThruSectionsC1Ebbd",
        "??0BRepOffsetAPI_ThruSections@@QEAA@_N0N@Z")) this(bool isSolid, bool ruled, double precision);

    pragma(mangle, cxxMangle!(
        "_ZN26BRepOffsetAPI_ThruSections7AddWireERK11TopoDS_Wire",
        "?AddWire@BRepOffsetAPI_ThruSections@@QEAAXAEBVTopoDS_Wire@@@Z")) void AddWire(ref const TopoDS_Wire wire);
    // Shape() is inherited from BRepBuilderAPI_MakeShape; use builtShape().
}
