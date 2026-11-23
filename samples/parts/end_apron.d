/** Left/right end apron of the coffee table. See parts/leg.d for the pattern. */
module parts.end_apron;

import dcad.shape : Shape;
import coffee_parts : makeEndApron;

Shape build()
{
    return makeEndApron();
}
