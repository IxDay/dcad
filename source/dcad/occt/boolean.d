/**
 * Boolean operations (BRepAlgoAPI subset).
 *
 * The progress-range argument is OCCT's default argument, made explicit in
 * the declarations because D cannot spell C++ default arguments.
 */
module dcad.occt.boolean;

import dcad.occt.types : opaqueWords, cxxMangle;
import dcad.occt.math : Message_ProgressRange;
import dcad.occt.topology : TopoDS_Shape;

extern(C++) struct BRepAlgoAPI_Cut
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN15BRepAlgoAPI_CutC1ERK12TopoDS_ShapeS2_RK21Message_ProgressRange",
        "??0BRepAlgoAPI_Cut@@QEAA@AEBVTopoDS_Shape@@0AEBVMessage_ProgressRange@@@Z")) this(ref const TopoDS_Shape a, ref const TopoDS_Shape b,
        ref const Message_ProgressRange progress);

    pragma(mangle, cxxMangle!(
        "_ZN15BRepAlgoAPI_CutD1Ev",
        "??1BRepAlgoAPI_Cut@@UEAA@XZ")) ~this();
}

extern(C++) struct BRepAlgoAPI_Fuse
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN16BRepAlgoAPI_FuseC1ERK12TopoDS_ShapeS2_RK21Message_ProgressRange",
        "??0BRepAlgoAPI_Fuse@@QEAA@AEBVTopoDS_Shape@@0AEBVMessage_ProgressRange@@@Z")) this(ref const TopoDS_Shape a, ref const TopoDS_Shape b,
        ref const Message_ProgressRange progress);

    pragma(mangle, cxxMangle!(
        "_ZN16BRepAlgoAPI_FuseD1Ev",
        "??1BRepAlgoAPI_Fuse@@UEAA@XZ")) ~this();
}

extern(C++) struct BRepAlgoAPI_Common
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN18BRepAlgoAPI_CommonC1ERK12TopoDS_ShapeS2_RK21Message_ProgressRange",
        "??0BRepAlgoAPI_Common@@QEAA@AEBVTopoDS_Shape@@0AEBVMessage_ProgressRange@@@Z")) this(ref const TopoDS_Shape a, ref const TopoDS_Shape b,
        ref const Message_ProgressRange progress);

    pragma(mangle, cxxMangle!(
        "_ZN18BRepAlgoAPI_CommonD1Ev",
        "??1BRepAlgoAPI_Common@@UEAA@XZ")) ~this();
}
