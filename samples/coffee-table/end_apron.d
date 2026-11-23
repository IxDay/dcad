/**
 * An end apron: a 432 mm rail with a raised strip on top and a slotted tenon
 * at each end. The wedge slot is cut into the tenon before it is attached.
 */
module end_apron;

import dcad.shape : Shape;
import dimensions;
import util;

private double wedgeRiseAt(double t)
{
    return wedgeTip + (wedgeRise - wedgeTip) *
        ((t + wedgeLength / 2) / wedgeLength);
}

/// A tapered void from inside the leg out to the wedge's sloping face.
private Shape wedgeSlot()
{
    immutable half = endApronTenonWidth / 2;
    immutable inner = legWidth + endApronTenonSlotOut;
    return prismXY([
        [inner, -half],
        [inner, half],
        [legWidth + wedgeRiseAt(half), half],
        [legWidth + wedgeRiseAt(-half), -half],
    ], wedgeHeight);
}

private Shape rawTenon()
{
    immutable hw = endApronTenonWidth / 2;
    immutable hh = endApronTenonHeight / 2;
    return cut(block(0, endApronTenonLength, -hw, hw, -hh, hh), wedgeSlot());
}

Shape build()
{
    auto tenon = rawTenon();
    return unionAll(
        block(0, endApronLength, -endApronWidth / 2, endApronWidth / 2,
              -endApronHeight / 2, endApronHeight / 2),
        block(0, endApronLength, -endApronWidth / 2, endApronWidth / 2,
              endApronHeight / 2, endApronHeight / 2 + transversalRise),
        moved(tenon, endApronLength, 0, 0),
        mirrorXAbout(tenon, 0));
}
