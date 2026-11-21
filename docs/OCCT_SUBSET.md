# Phase 1: first OCCT binding subset

Goal of the first cut: boxes, cylinders, sketch wires/faces, extrusion,
boolean operations, fillets/chamfers, STEP export, plus just enough topology
inspection to drive typed selectors and to validate results. Everything in
"Bound now" has a compiling `extern(C++)` declaration in `source/dcad/occt/`
and is exercised by at least one example.

## Bound now (direct `extern(C++)`)

| Module | OCCT classes | Why it is in the first cut |
|---|---|---|
| `types.d` | `Standard_Real/Integer/Boolean`, `TopAbs_ShapeEnum`, `IFSelect_ReturnStatus`, `STEPControl_StepModelType`, `ChFi3d_FilletShape` | ABI primitives and closed sets; become D aliases/enums. |
| `math.d` | `gp_XYZ`, `gp_Pnt`, `gp_Vec`, `gp_Dir`, `gp_Ax2`, `gp_Ax1`, `gp_Trsf`, `Message_ProgressRange` | Positions, directions and frames for every builder. `gp_*` value types are mirrored layout-for-layout in D because all their methods are inline C++; `gp_Ax2` uses its out-of-line constructor. |
| `topology.d` | `TopoDS_Shape`, `TopoDS_Solid/Face/Wire/Edge/Vertex`, `BRepBuilderAPI_MakeShape`, `BRepAlgoAPI_Algo` | Handle-like topology values; base classes let us reach the non-overridden `Shape()` implementation. |
| `prim.d` | `BRepPrimAPI_MakeBox`, `BRepPrimAPI_MakeCylinder`, `BRepPrimAPI_MakePrism` | Box/cylinder primitives and extrusion. |
| `builder.d` | `BRepBuilderAPI_MakePolygon`, `BRepBuilderAPI_MakeWire`, `BRepBuilderAPI_MakeFace`, `BRepBuilderAPI_MakeEdge` | Sketch → wire → face path. |
| `boolean.d` | `BRepAlgoAPI_Cut/Fuse/Common` | The three boolean ops CadQuery uses most. |
| `fillet.d` | `BRepFilletAPI_MakeFillet`, `BRepFilletAPI_MakeChamfer` | Edge-based rounding/beveling. |
| `loft.d` | `BRepOffsetAPI_ThruSections` | Loft acceptance example. |
| `io.d` | `STEPControl_Writer` | `Transfer` + `Write`; Handle-returning methods deliberately omitted. |

## Thin C++ shim (`shim/dcad_shim.cpp`)

Only the pieces that plain `extern(C++)` cannot express, about 150 lines:

* Inline OCCT accessors with no linkable symbol: `IsNull`, `ShapeType`,
  `gp_Pnt::X/Y/Z`, explorer traversal (`dcad_subshape_*`).
* Exception containment: `try/catch (const Standard_Failure&)` around
  box/cylinder/cut/fuse/fillet/extrude/STEP write, translating to status codes
  plus `dcad_last_error()`.
* Shape ownership: `dcad_shape_clone` / `dcad_shape_free` give D's GC a simple
  pointer to a C++ heap shape.
* `gp_Circ` → edge → wire → face for circular sketches: the OCCT API takes
  `Handle(Geom_Curve)`, which cannot be declared in `extern(C++)`.
* Volume and bounding box (`BRepGProp`, `BRepBndLib`) used for validation and
  selector classification.

## Deliberately deferred

* IGES export (`IGESControl_Writer`) — same pattern as STEP, low risk.
* Revolve (`BRepPrimAPI_MakeRevol`), sweep (`BRepOffsetAPI_MakePipe`) — the
  latter needs a `Handle(Geom_Curve)` shim.
* Mesh extraction for previews (`BRepMesh_IncrementalMesh` is bound-ready, but
  `BRep_Tool::Triangulation` returns `Handle(Poly_Triangulation)`, so this
  needs a shim; see `docs/PHASE3.md`).
* Importers, XCAF/colors, tolerances/offsets, algorithm history tracking,
  and higher-level `BRepAlgoAPI` interfaces.

## Code generation decision

**Recommendation: keep the subset hand-written for now; do not build a header
parser yet.** Reasons:

* The first cut is ~15 classes; hand-writing them surfaced all the real ABI
  problems (inline methods, virtual `Shape()`, default args, deleted zero-arg
  D constructors, `Handle` templates). A generator would have hidden those
  behind generated code that still needs the same manual fixes.
* `dpp` (the existing C++ header translator) explicitly has limited C++
  support, is Linux/libclang-only, and chokes on STL/template-heavy headers —
  OCCT is exactly that case.
* Once the binding set grows past ~50 classes, generate from a small curated
  annotation file (class name + chosen overloads + shim markers), not from raw
  headers. That keeps the ABI decisions explicit and reviewable.
