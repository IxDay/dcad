# Daimochi-tsugi — 台持ち継ぎ

This project is the default scaffold created by **File > New Project** in
`dcad-gui`. It is an ordinary directory of D source: no hidden session state, no
generated cache, and nothing that only exists inside the GUI.

## Open and run

Open the directory itself (`dcad-gui /path/to/this-directory`) or open
`dcad.json` as a project handler, then click a `.d` file in the sidebar and
press **Cmd/Ctrl+Enter**. Each part opens and renders on its own; `main.d` opens
the complete assembly and its take-apart animation.

`dcad.json` is the project manifest:

- `entry` names the assembly source shown on open;
- every `.d` file beside it is compiled into the hot-loaded plugin, so helper
  modules can be imported by their file name;
- **Save** writes only the file currently open in the editor.

## Files

| File | Purpose |
|---|---|
| `dcad.json` | Project manifest (name and entry point) |
| `main.d` | Assembly entry point: `dcadMain()`, `dcadParts()`, `dcadPoses()` |
| `dimensions.d` | Shared millimetre dimensions |
| `daimochi_util.d` | Small wrappers over the dcad/OCCT shim |
| `part_a.d` | Receiving beam (part A) |
| `part_b.d` | Shelved beam with the housed tenon (part B) |
| `key.d` | The komisen through-key |
| `motion.d` | Closed → exploded → closed keyframes |

To make a variant, edit one part file and run it by itself first. Because the
parts are unions of rectangular blocks, a pocket is just a smaller set of
blocks: remove a range from a block, or split it around the void.

## Geometry credit

The block layout is derived from the face polygons in
[IxDay/carpentry](https://github.com/IxDay/carpentry/blob/main/joints/sources/daimochi-tsugi.json),
used under [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/).
Reference: https://ixday.github.io/carpentry/#daimochi-tsugi
