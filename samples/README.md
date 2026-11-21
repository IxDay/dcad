# Samples

Each subdirectory is an independent `dub` executable subpackage in this repo.
The browser viewer component is **not** included; samples produce CAD data
files (currently STEP) plus any metadata they need.

| Sample | Output | Description |
| --- | --- | --- |
| [`coffee-table/`](coffee-table/) | `table/*.step`, `coffee-table.step`, `table/animation.json` | 18-part mortise-and-tenon timber table ported from the `platipy/coffee-table` CadQuery project (via the `cadquery/samples/coffee-table` Go sample). |

## Build one sample

```bash
dub run :coffee-table
```

See [`docs/OUTPUT_FORMATS.md`](../docs/OUTPUT_FORMATS.md) for what other output
formats would cost to add.
