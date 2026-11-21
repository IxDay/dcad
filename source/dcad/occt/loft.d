/**
 * Loft through a set of wires (BRepOffsetAPI subset).
 */
module dcad.occt.loft;

import dcad.occt.types : opaqueWords;
import dcad.occt.topology : TopoDS_Wire;

extern(C++) struct BRepOffsetAPI_ThruSections
{
    void*[opaqueWords] _opaque;

    this(bool isSolid, bool ruled, double precision);
    void AddWire(ref const TopoDS_Wire wire);
    // Shape() is inherited from BRepBuilderAPI_MakeShape; use builtShape().
}
