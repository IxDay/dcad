/**
 * Daimochi-tsugi assembly — the project's entry point.
 *
 * Open this file and press Run for the closed joint with its take-apart
 * animation. Open part_a.d, part_b.d or key.d to work on one timber alone.
 */
module daimochi_main;

import dcad.shape : Shape;
import utils : NamedPart, compound;
import dimensions;
import motion : allPoses, posedParts;
import part_a : makePartA = build;
import part_b : makePartB = build;
import key : makeKey = build;

/// The closed joint, with stable ids shared by the animation and parts list.
NamedPart[] daimochiParts()
{
    return [
        NamedPart("part-a", "Receiving beam", makePartA()),
        NamedPart("part-b", "Shelved beam", makePartB()),
        NamedPart("key", "Komisen key", makeKey()),
    ];
}

/// Module-style GUI entry point.
Shape dcadMain()
{
    Shape[] shapes;
    foreach (part; daimochiParts())
        shapes ~= part.shape;
    return compound(shapes);
}

/// Optional animation hooks consumed by the GUI wrapper.
NamedPart[] dcadParts()
{
    return daimochiParts();
}

double[3][string][] dcadPoses()
{
    return allPoses();
}
