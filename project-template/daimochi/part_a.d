/**
 * Part A — the receiving beam.
 *
 * Open this file in the GUI and press Run to see the beam alone. The main
 * block ends at X=0; the stepped tenon and the two shelf cheeks project to
 * X=100. The empty band between the cheeks is the komisen mortise.
 */
module part_a;

import dcad.shape : Shape;
import daimochi_util : block, unionAll;

Shape build()
{
    return unionAll(
        // Full-section beam.
        block(-450,   0,   0,     0, 120, 120),
        // Housed tenon: rests on the mortise floor, spans the middle band.
        block(   0,  30,  30,   100,  45,  90),
        // Upper cheek, carried by the 50 mm shelf.
        block(   0,  45,  30,    20, 120,  90),
        // Lower shelf lip, front and back.
        block(   0,  90,   0,    50, 120,  30),
        block(   0,  90,  90,    50, 120, 120),
        // The tenon continues into the far cheek; the 30 mm gap between
        // Y=45..75 is the through-mortise for the key.
        block(  20,  75,  30,   100,  90,  90),
        block(  20,  90,  30,    50, 120,  90),
        block(  50,  45,  30,   100,  75,  90));
}
