/** Wedged tenon of the coffee table. See parts/leg.d for the pattern. */
module parts.wedge;

import dcad.shape : Shape;
import coffee_parts : makeWedge;

Shape build()
{
    return makeWedge();
}
