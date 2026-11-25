/**
 * Part B — the incoming beam.
 *
 * The reference source builds this piece at X=300..750; it is translated by
 * -300 here so the closed pose is assembled at X=0..450. The shelf at the left
 * end straddles part A's projecting tenon.
 */
module part_b;

import dcad.shape : Shape;
import daimochi_util : block, unionAll;

Shape build()
{
    return unionAll(
        // Lower half of the beam and the lower shelf cheek.
        block(  0,   0,   0,  450,  45,  30),
        block(  0,   0,  30,  450,  30, 120),
        block(  0,  30,  90,  450,  45, 120),
        // Mortise walls around part A's tenon.
        block(  0,  45,   0,   20,  90,  30),
        block(  0,  45,  90,   20,  90, 120),
        block( 20,  75,   0,  450,  90,  30),
        block( 20,  75,  90,  450,  90, 120),
        block( 50,  45,   0,  450,  75,  30),
        block( 50,  45,  90,  450,  75, 120),
        // Far cheek.
        block( 50,  90,   0,  450, 120, 120),
        block(100,  30,  30,  450,  90,  90));
}
