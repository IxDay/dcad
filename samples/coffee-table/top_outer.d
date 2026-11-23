/**
 * An outer top plank: grooves for the two end-apron tenons, the two cross-rail
 * tenons, and the two leg tabs.
 */
module top_outer;

import dcad.shape : Shape;
import dimensions;
import util;

Shape build()
{
    immutable anchors = apronAnchors();
    auto base = block(0, topLength, 0, topWidth, 0, topHeight);
    immutable hw = endApronWidth / 2;
    immutable lw = legWidth / 2;
    return cutAll(base,
        // End-apron tenon grooves, running from the legs inward.
        block(anchors[0] - hw, anchors[0] + hw, legInset + legWidth, topWidth + 1,
              -1, anchor + 1),
        block(anchors[3] - hw, anchors[3] + hw, legInset + legWidth, topWidth + 1,
              -1, anchor + 1),
        // Cross-rail tenon grooves, nearer the plank's inner edge.
        block(anchors[1] - hw, anchors[1] + hw,
              (totalWidth - endApronInternalLength) / 2, topWidth + 1, -1, anchor + 1),
        block(anchors[2] - hw, anchors[2] + hw,
              (totalWidth - endApronInternalLength) / 2, topWidth + 1, -1, anchor + 1),
        // Leg-tab pockets; only the outer wall of each leg's notch enters.
        block(anchors[0] - lw, anchors[0] + lw, legInset, legInset + legNotchWidth,
              -1, anchor + 1),
        block(anchors[3] - lw, anchors[3] + lw, legInset, legInset + legNotchWidth,
              -1, anchor + 1));
}
