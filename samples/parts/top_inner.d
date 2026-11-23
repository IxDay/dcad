/** Inner top plank of the coffee table. See parts/leg.d for the pattern. */
module parts.top_inner;

import dcad.shape : Shape;
import coffee_parts : makeTopInternal;

Shape build()
{
    return makeTopInternal();
}
