// Coffee-table knock-down animation -- paste into the editor with File >
// Reset to example replaced, or copy the whole file into the script pane.
import coffee_parts : tableParts;
import coffee_util : compound;
import coffee_motion : allPoses;
import dcad.shape : Shape;

auto parts = tableParts();
Shape[] shapes;
foreach (p; parts)
    shapes ~= p.shape;

// The static result (also what Export STEP writes).
Shape result = compound(shapes);

// Optional GUI animation hooks. animParts supplies one mesh per part;
// animPoses holds the keyframes (one offset map per frame, t in [0,1]).
auto animParts = parts;
auto animPoses = allPoses();
