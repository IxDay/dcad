/**
 * Boolean operations (BRepAlgoAPI subset).
 *
 * The progress-range argument is OCCT's default argument, made explicit in
 * the declarations because D cannot spell C++ default arguments.
 */
module dcad.occt.boolean;

import dcad.occt.types : opaqueWords;
import dcad.occt.math : Message_ProgressRange;
import dcad.occt.topology : TopoDS_Shape;

extern(C++) struct BRepAlgoAPI_Cut
{
    void*[opaqueWords] _opaque;
    this(ref const TopoDS_Shape a, ref const TopoDS_Shape b,
         ref const Message_ProgressRange progress);
    ~this();
}

extern(C++) struct BRepAlgoAPI_Fuse
{
    void*[opaqueWords] _opaque;
    this(ref const TopoDS_Shape a, ref const TopoDS_Shape b,
         ref const Message_ProgressRange progress);
    ~this();
}

extern(C++) struct BRepAlgoAPI_Common
{
    void*[opaqueWords] _opaque;
    this(ref const TopoDS_Shape a, ref const TopoDS_Shape b,
         ref const Message_ProgressRange progress);
    ~this();
}
