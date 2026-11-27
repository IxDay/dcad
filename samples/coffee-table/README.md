# Coffee table (dcad / OCCT port)

A direct D port of `../../cadquery/samples/coffee-table` (a Go/fluent-sdfx port
of the CadQuery model in `platipy/coffee-table`). The same modules drive the
GUI's live 3D preview; `table.d` also has an optional standalone main that emits
**exact B-rep STEP files** instead of decimated STL meshes.

This directory is a complete dcad project: the legacy `.dcad.toml` marker names
`table.d` as its entry point. Launch the GUI from here to open it directly, or
choose this folder in the first-run "Open existing project" dialog. The GUI
never opens a sample implicitly.

The model is a **1400 × 600 × 362 mm knock-down timber table** with traditional
mortise-and-tenon joinery. X runs along the table 0…1400, Y across it −300…300,
Z up 0…362.

| Part | Qty | Notes |
| --- | --- | --- |
| Legs | 4 | 54 × 54 × 342, side-apron notch, 8 mm locating tab, through mortise |
| Long aprons | 2 | 1340 × 20 × 64, end-apron slots and four shallow cross-rail mortises |
| End aprons | 2 | 432 × 20 × 64 + 8 mm rise, slotted tenon at each end |
| Cross rails | 2 | 466 × 20 × 64 + rise, 8 mm tenon at each end |
| Top planks | 4 | 1400 × 150 × 28, grooved for tenons and leg tabs |
| Wedges | 4 | Tapered blocks driven into the end-apron tenons |

## Files

| File | Role |
| --- | --- |
| `dimensions.d` | constants, `legX()`, `apronAnchors()`, `block()` |
| `util.d` | shim wrappers: transform, cut/union, centred prism, export |
| `leg.d`, `side_apron.d`, `end_apron.d`, `cross_rail.d`, `top_outer.d`, `top_inner.d`, `wedge.d` | one runnable module per element, each exposing `Shape build()` |
| `motion.d` | knock-down animation tracks → JSON |
| `table.d` | imports every part plus the motion, assembles the 18 timbers, and exposes the GUI entry points (`dcadMain`, `dcadParts`, `dcadPoses`); its version-gated `main` writes the outputs |

Open any element file (or `table.d`) in the GUI and press Run to render it. The
standalone main uses two shim helpers beyond the core library (both in
`shim/dcad_shim.cpp`): `dcad_guarded_transform` (gp_Trsf +
BRepBuilderAPI_Transform, since `gp_Trsf`'s constructors are inline) and
`dcad_make_compound`.

## Build

```bash
dub run :coffee-table       # STEP files + animation JSON, from the repo root
dub run :gui                # preview an element or the whole animated table
```

## Outputs

- `table/<part-id>.step` — 18 exact B-rep STEP files, one per named timber.
- `coffee-table.step` — all 18 parts in a single `TopoDS_Compound` (a compound,
  not a boolean union: the timbers remain separate solids).
- `table/animation.json` — translation tracks for the 14 parts that move during
  the knock-down sequence, generated from the same stage data as the reference.
  Track selectors use `.step` names to match the files actually written.

Generated files are gitignored and recreated on every run.

## Validation

Run `./tests/run.sh` from the repository root. The sample asserts the assembly
bounds are exactly 1400 × 600 × 362 mm. Compared with the reference STL meshes:

- every part's bounding box matches exactly (wedge `y` agrees to the 0.1 mm
  marching-cubes tolerance);
- per-part volumes agree within 0.05% for the large timbers and 0.4% for the
  small wedges, well inside the reference's stated 0.5% decimation tolerance.

The only deliberate difference from the reference sample is file format: STEP
instead of STL. See `docs/OUTPUT_FORMATS.md` for what adding other formats
would involve.
