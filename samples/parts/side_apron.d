/** Front/back long apron of the coffee table. See parts/leg.d for the pattern. */
module parts.side_apron;

import dcad.shape : Shape;
import coffee_parts : makeSideApron;

Shape build()
{
    return makeSideApron();
}
