/**
 * One coffee-table element as its own runnable module.
 *
 * Open this file in the GUI and press Run: the host compiles it as a module
 * and calls build(), so the element alone appears in the preview. Assembly
 * scripts can import it as `parts.leg : build`.
 */
module parts.leg;

import dcad.shape : Shape;
import coffee_parts : makeLeg;

Shape build()
{
    return makeLeg();
}
