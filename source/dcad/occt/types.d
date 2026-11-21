/**
 * The OCCT subset's primitive types and enums.
 *
 * These are direct translations of OCCT's Standard_TypeDef.hxx and a handful
 * of enum headers. Nothing here needs a C++ shim.
 */
module dcad.occt.types;

alias Standard_Real = double;
alias Standard_Integer = int;
alias Standard_Boolean = bool;
alias Standard_CString = const(char)*;

/// OCCT's TopAbs_ShapeEnum (src/TopAbs/TopAbs_ShapeEnum.hxx).
enum TopAbs_ShapeEnum : int
{
    compound = 0,
    compSolid,
    solid,
    shell,
    face,
    wire,
    edge,
    vertex,
    shape
}

enum TopAbs_Orientation : int
{
    forward_, reversed_, internal_, external_
}

enum IFSelect_ReturnStatus : int
{
    retVoid = 0,
    retDone,
    retError,
    retFail,
    retStop
}

enum STEPControl_StepModelType : int
{
    asIs = 0,
    manifoldSolidBrep,
    brepWithVoids,
    facetedBrep,
    facetedBrepAndBrepWithVoids,
    shellBasedSurfaceModel,
    geometricCurveSet,
    hybrid
}

enum ChFi3d_FilletShape : int
{
    rational = 0,
    quasiAngular = 1,
    polynomial = 2
}

/**
 * Storage reserved for a C++ object that D only ever refers to by address.
 *
 * LDC allocates extern(C++) structs using the D-side size. Oversized storage
 * is intentional: the C++ constructor writes the real layout into this
 * buffer, and D never reads it. C++ objects are never returned by value to D.
 */
enum size_t opaqueWords = 64;  // 512 bytes on 64-bit targets
