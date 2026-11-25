/**
 * STEP export (STEPControl subset). Handle-returning methods (Model(), WS())
 * are deliberately not bound: they use opencascade::handle<T> templates.
 */
module dcad.occt.io;

import dcad.occt.types : opaqueWords, STEPControl_StepModelType,
    IFSelect_ReturnStatus, cxxMangle;
import dcad.occt.math : Message_ProgressRange;
import dcad.occt.topology : TopoDS_Shape;

extern(C++) struct STEPControl_Writer
{
    void*[opaqueWords] _opaque;

    pragma(mangle, cxxMangle!(
        "_ZN18STEPControl_WriterC1Ev",
        "??0STEPControl_Writer@@QEAA@XZ")) this(int dummy);

    pragma(mangle, cxxMangle!(
        "_ZN18STEPControl_Writer8TransferERK12TopoDS_Shape25STEPControl_StepModelTypebRK21Message_ProgressRange",
        "?Transfer@STEPControl_Writer@@QEAA?AW4IFSelect_ReturnStatus@@AEBVTopoDS_Shape@@W4STEPControl_StepModelType@@_NAEBVMessage_ProgressRange@@@Z")) IFSelect_ReturnStatus Transfer(ref const TopoDS_Shape shape,
        STEPControl_StepModelType mode, bool composeGraph,
        ref const Message_ProgressRange progress);

    pragma(mangle, cxxMangle!(
        "_ZN18STEPControl_Writer5WriteEPKc",
        "?Write@STEPControl_Writer@@QEAA?AW4IFSelect_ReturnStatus@@QEBD@Z")) IFSelect_ReturnStatus Write(const(char)* fileName);
}
