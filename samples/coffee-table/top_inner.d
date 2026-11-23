/** An inner top plank: four cross-rail grooves cut right through its width. */
module top_inner;

import dcad.shape : Shape;
import dimensions;
import util;

Shape build()
{
    auto base = block(0, topLength, 0, topWidth, 0, topHeight);
    immutable hw = endApronWidth / 2;
    Shape[] tools;
    foreach (a; apronAnchors())
        tools ~= block(a - hw, a + hw, -1, topWidth + 1, -1, anchor + 1);
    return cutAll(base, tools);
}
