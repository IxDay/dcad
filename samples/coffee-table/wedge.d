/** A tapered block driven into each end-apron tenon's slot. */
module wedge;

import dcad.shape : Shape;
import dimensions;
import util;

Shape build()
{
    immutable half = wedgeLength / 2;
    return prismXY([
        [legWidth, -half],
        [legWidth, half],
        [legWidth + wedgeRise, half],
        [legWidth + wedgeTip, -half],
    ], wedgeHeight);
}
