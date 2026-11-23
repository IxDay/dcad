/** Internal cross rail of the coffee table. See parts/leg.d for the pattern. */
module parts.cross_rail;

import dcad.shape : Shape;
import coffee_parts : makeEndApronInternal;

Shape build()
{
    return makeEndApronInternal();
}
