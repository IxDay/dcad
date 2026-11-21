# Output formats: what is cheap to add

The coffee-table sample currently writes **18 exact B-rep STEP files** (one per
timber), one compound STEP for the whole assembly, and a motion JSON. All
geometry is exact OCCT topology — nothing is tessellated on the way out.

The table below is ordered by implementation cost *on top of the existing
bindings*. "Effort" assumes one small C++ shim function (5–30 lines), because
every OCCT writer takes C++ types (`Handle(...)`, `Standard_OStream`, XCAF
labels) that cannot be declared in `extern(C++)`.

| Format | Stores | Effort | OCCT entry point | Notes |
|---|---|---|---|---|
| **STEP** (AP214) | exact B-rep | **done** | `STEPControl_Writer` | Already used. Per part and as a compound. No names/colours in the plain writer. |
| **BREP** | exact B-rep | trivial | `BRepTools::Write` | OCCT's own format; perfect round-trip, fastest to write/read. Ideal for caches and tests. ~8 lines in the shim. |
| **IGES** | exact B-rep | trivial | `IGESControl_Writer` | Same shape as the STEP code (`AddShape` + `Write`). Link `TKDEIGES`. Older interchange; weaker on assembly structure. |
| **CSV / JSON manifest** | bounds, volume, part ids | trivial | existing `dcad_bbox` / `dcad_volume` | No new OCCT code at all. Useful for validation and for driving a UI list. |
| **STL** (binary) | triangles only | small | `BRepMesh_IncrementalMesh` + `StlAPI_Writer` / `RWStl` | This is what the Go sample emits for the browser viewer. Lossy; needs a mesh density choice. Link `TKMesh`. |
| **OBJ** (+ MTL) | triangles + material names | small | `RWObj_CafWriter` (XCAF doc) or hand-rolled from `Poly_Triangulation` | Hand-rolled from a mesh is easier than the XCAF route if names are not needed. |
| **STEP with names** (XCAF) | exact B-rep + assembly tree + labels | moderate | `STEPCAFControl_Writer`, `XCAFDoc_DocumentTool` | The single most valuable upgrade: one file with all 18 parts named, instead of 18 loose files. Needs `TKXCAF` and a small XCAF setup. |
| **glTF / GLB** | triangles + PBR materials | moderate | `RWGltf_CafWriter` | Requires a filled XCAF document (same work as named STEP). Best for a web viewer; not an exact CAD format. |
| **SVG** | projected edges | moderate | tessellate edges, emit XML | Easy for a 2D plan/elevation sheet, but needs hidden-line removal to look like a drawing. |
| **DXF** | 2D/3D linework | moderate | no base-OCCT writer | Would have to be written directly from projected curves. |
| **AMF / 3MF** | triangles + print metadata | moderate | no OCCT writer | 3MF additionally needs zip packaging; only worth it for additive manufacturing. |

## Recommendation for this sample

1. **Keep STEP per part** as the authoritative output — it is exact and already
   validated part-for-part against the reference (bounds exact, volumes within
   0.05%).
2. **Add BREP next** if intermediate results need to be cached or diffed; it is
   the cheapest exact format and removes STEP parse cost from every test run.
3. **Add STL only when rendering is back on the table.** It is ~20 lines, but
   it throws away the exact geometry, so it should be a *view* artifact rather
   than the source of truth.
4. **Add named-assembly STEP (XCAF)** if a downstream CAD tool needs one file
   with 18 labelled components. This is the natural successor to the current
   `coffee-table.step` compound, which has no part names.

## What is deliberately *not* proposed

Generating a full C wrapper around OCCT just to get more formats. Every entry
in the "trivial/small" rows is a single shim function; the expensive part of
glTF and named STEP is the XCAF document model, not the D↔C++ boundary.

The `animation.json` produced here is data, not rendering: it stores translation
tracks for the 14 moving parts and needs no mesh or viewer. Selectors point at
`.step` files so they match what is actually written; switching to `.stl`
selectors later is a one-line change.
