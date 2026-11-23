/**
 * Module-style GUI script: a real D module, not a script body.
 *
 * The host imports it and calls dcadMain(); the optional dcadParts() /
 * dcadPoses() hooks enable animation and may come from imported files. Open
 * this file in the GUI and press Run to see the assembled, animated table.
 * Legacy body-style scripts (default.d, coffee-table-animation.d) still work.
 */
module module_assembly;

import dcad.shape : Shape;
import util : NamedPart, compound;
import table : tableParts;
import motion : allPoses;

Shape dcadMain()
{
    Shape[] shapes;
    foreach (p; tableParts())
        shapes ~= p.shape;
    return compound(shapes);
}

NamedPart[] dcadParts()
{
    return tableParts();
}

double[3][string][] dcadPoses()
{
    return allPoses();
}
