/**
 * A long apron: through slots for the end-apron tenons plus the leg mortises.
 * The reference's `.center(-30, 0)` shifts every pushPoint by -30, so the
 * mortises sit 30 mm left of the anchors.
 */
module side_apron;

import dcad.shape : Shape;
import dimensions;
import util;

private Shape[] endApronCut(double x)
{
    immutable hw = endApronTenonWidth / 2;
    immutable pocket = sideApronWidth / 2 - legApronAnchor; // 7
    return [
        block(x - hw, x + hw, -pocket, pocket,
              -endApronTenonHeight / 2, endApronTenonHeight / 2),
        block(x - legWidth / 2, x + legWidth / 2, pocket, sideApronWidth / 2,
              -sideApronHeight / 2, sideApronHeight / 2),
        block(x - legWidth / 2, x + legWidth / 2, -sideApronWidth / 2, -pocket,
              -sideApronHeight / 2, sideApronHeight / 2),
    ];
}

Shape build()
{
    auto base = block(0, sideApronLength, -sideApronWidth / 2, sideApronWidth / 2,
                      -sideApronHeight / 2, sideApronHeight / 2);

    immutable anchors = apronAnchors();
    immutable external = [anchors[0] - sideApronMarginEnd,
                          anchors[3] - sideApronMarginEnd];
    Shape[] tools;
    foreach (x; external)
        tools ~= endApronCut(x);
    foreach (a; anchors)
    {
        immutable x = a - sideApronMarginEnd;
        tools ~= block(x - endApronTenonWidth / 2, x + endApronTenonWidth / 2,
                       -sideApronWidth / 2 - 1, -sideApronWidth / 2 + anchor,
                       -endApronTenonHeight / 2, endApronTenonHeight / 2);
    }
    return cutAll(base, tools);
}
