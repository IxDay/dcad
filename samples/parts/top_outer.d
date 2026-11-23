/** Outer top plank of the coffee table. See parts/leg.d for the pattern. */
module parts.top_outer;

import dcad.shape : Shape;
import coffee_parts : makeTopExternal;

Shape build()
{
    return makeTopExternal();
}
