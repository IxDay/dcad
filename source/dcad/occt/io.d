/**
 * STEP export (STEPControl subset). Handle-returning methods (Model(), WS())
 * are deliberately not bound: they use opencascade::handle<T> templates.
 */
module dcad.occt.io;

import dcad.occt.types : opaqueWords, STEPControl_StepModelType,
    IFSelect_ReturnStatus;
import dcad.occt.math : Message_ProgressRange;
import dcad.occt.topology : TopoDS_Shape;

extern(C++) struct STEPControl_Writer
{
    void*[opaqueWords] _opaque;

    pragma(mangle, "_ZN18STEPControl_WriterC1Ev") this(int dummy);

    IFSelect_ReturnStatus Transfer(ref const TopoDS_Shape shape,
                                   STEPControl_StepModelType mode,
                                   bool composeGraph,
                                   ref const Message_ProgressRange progress);

    IFSelect_ReturnStatus Write(const(char)* fileName);
}
