/**
 * Komisen — the square through-key.
 *
 * The reference places this peg at Z=260..435 mm, Y=185..215 mm before the
 * assemble step. It is already shifted into the closed pose here; `motion.d`
 * pulls it out along +Y and +Z for the animation.
 */
module key;

import dcad.shape : Shape;
import daimochi_util : block;

Shape build()
{
    return block(20, 45, -20, 50, 75, 155);
}
