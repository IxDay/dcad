/**
 * An internal cross rail with a tenon at each end and a raised strip between
 * them. Python builds half the rail and mirrors it; drawing the doubled body
 * as one box avoids a zero-valued SDF seam where the halves would meet.
 */
module cross_rail;

import dcad.shape : Shape;
import dimensions;
import util;

Shape build()
{
    immutable half = endApronInternalLength / 4;
    immutable x0 = -3 * half;
    immutable x1 = half;
    immutable hw = endApronTenonWidth / 2;
    immutable hh = endApronTenonHeight / 2;

    return unionAll(
        block(x0, x1, -endApronWidth / 2, endApronWidth / 2,
              -endApronHeight / 2, endApronHeight / 2),
        block(x1, x1 + anchor, -hw, hw, -hh, hh),
        block(x0 - anchor, x0, -hw, hw, -hh, hh),
        block(x0, x1, -endApronWidth / 2, endApronWidth / 2,
              endApronHeight / 2, endApronHeight / 2 + transversalRise));
}
