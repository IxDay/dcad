/**
 * The eighteen timbers of the knock-down coffee table.
 *
 * Direct D port of parts.go, which itself ports the platipy/coffee-table
 * CadQuery project. Every mortise, tenon, pocket and groove is modelled.
 */
module coffee_parts;

import dcad.shape : Shape;
import coffee_dimensions;
import coffee_util;

/// legs.py: a 54 square post with a side-apron notch, an 8 mm locating tab
/// above the aprons' seat, and a through mortise for the end-apron tenon.
Shape makeLeg()
{
    auto leg = block(-legWidth / 2, legWidth / 2, 0, legWidth, 0, legHeight);
    immutable notchLo = legHeight - anchor - sideApronHeight; // 270
    return cutAll(leg,
        // Side-apron notch, centred across the leg.
        block(-legWidth, legWidth, (legWidth - legNotchWidth) / 2,
              (legWidth + legNotchWidth) / 2, notchLo, legHeight + 1),
        // The inner half is cut down to the apron's seat; the outer wall
        // remains as the tab that enters the top plank's pocket.
        block(-legWidth, legWidth, legWidth / 2, legWidth + 1,
              frameZ, legHeight + 1),
        // End-apron tenon mortise, through from face to face.
        block(-endApronTenonWidth / 2, endApronTenonWidth / 2,
              -1, legWidth + 1, apronZ - endApronTenonHeight / 2,
              apronZ + endApronTenonHeight / 2));
}

/// aprons.py's end_apron_cut: a narrow through slot for the tenon, widened into
/// shallow pockets on both faces for the legs' 3 mm recess.
Shape[] endApronCut(double x)
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

/// aprons.py's side_apron. The reference's `.center(-30, 0)` shifts every
/// later pushPoint by -30, so the mortises sit 30 mm left of the anchors.
Shape makeSideApron()
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

double wedgeRiseAt(double t)
{
    return wedgeTip + (wedgeRise - wedgeTip) *
        ((t + wedgeLength / 2) / wedgeLength);
}

/// wedges.py's slot(): a tapered void from inside the leg out to the wedge's
/// sloping face. Cut from each end-apron tenon.
Shape wedgeSlot()
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

/// The tenon before it is attached to either end of the apron.
Shape rawTenon()
{
    immutable hw = endApronTenonWidth / 2;
    immutable hh = endApronTenonHeight / 2;
    return cut(block(0, endApronTenonLength, -hw, hw, -hh, hh), wedgeSlot());
}

/// aprons.py's end_apron: a 432 mm rail with a raised strip on top and a
/// slotted tenon at each end.
Shape makeEndApron()
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

/// aprons.py's end_apron_internal: a cross rail with a tenon at each end and
/// the same raised strip between them. Python builds half the rail and mirrors
/// it about its own end face; drawing the doubled body as one box avoids a
/// zero-valued SDF seam where the two halves would meet.
Shape makeEndApronInternal()
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

/// top_external.py: a 1400 x 150 plank with grooves for the two end-apron
/// tenons, the two cross-rail tenons, and the two leg tabs.
Shape makeTopExternal()
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

/// top_internal.py: four cross-rail grooves cut right through the 150 mm
/// width.
Shape makeTopInternal()
{
    auto base = block(0, topLength, 0, topWidth, 0, topHeight);
    immutable hw = endApronWidth / 2;
    Shape[] tools;
    foreach (a; apronAnchors())
        tools ~= block(a - hw, a + hw, -1, topWidth + 1, -1, anchor + 1);
    return cutAll(base, tools);
}

/// wedges.py's wedge(): a tapered block driven into each tenon's slot.
Shape makeWedge()
{
    immutable half = wedgeLength / 2;
    return prismXY([
        [legWidth, -half],
        [legWidth, half],
        [legWidth + wedgeRise, half],
        [legWidth + wedgeTip, -half],
    ], wedgeHeight);
}

/// All eighteen timbers in the closed pose, as table.py's parts() returns.
NamedPart[] tableParts()
{
    immutable legXPos = legX();
    immutable left = legXPos[0];
    immutable right = legXPos[1];
    immutable anchors = apronAnchors();
    immutable railLeft = anchors[1];
    immutable railRight = anchors[2];
    immutable nearY = -sideApronOffset;
    immutable farY = sideApronOffset;

    auto leg = makeLeg();
    auto sideApron = makeSideApron();
    auto endApron = makeEndApron();
    auto rail = makeEndApronInternal();
    auto topOuter = makeTopExternal();
    auto topInner = makeTopInternal();
    auto wedge = makeWedge();

    NamedPart[] out_ = [
        NamedPart("leg-near-left", "front left leg",
                  place(leg, 0, left, frameFY + legInset, 0, false)),
        NamedPart("leg-near-right", "front right leg",
                  place(leg, 0, right, frameFY + legInset, 0, false)),
        NamedPart("leg-far-left", "back left leg",
                  place(leg, 180, left, frameFY + totalWidth - legInset, 0, false)),
        NamedPart("leg-far-right", "back right leg",
                  place(leg, 180, right, frameFY + totalWidth - legInset, 0, false)),
        // The near apron is mirrored so its mortised face points inward.
        NamedPart("apron-side-near", "front long apron",
                  place(sideApron, 0, sideApronMarginEnd, nearY, apronZ, true)),
        NamedPart("apron-side-far", "back long apron",
                  place(sideApron, 0, sideApronMarginEnd, farY, apronZ, false)),
        NamedPart("apron-end-left", "left end apron",
                  place(endApron, 90, left, -endApronLength / 2, apronZ, false)),
        NamedPart("apron-end-right", "right end apron",
                  place(endApron, 270, right, endApronLength / 2, apronZ, false)),
        NamedPart("rail-cross-left", "left cross rail",
                  place(rail, 90, railLeft, endApronInternalLength / 4, apronZ, false)),
        NamedPart("rail-cross-right", "right cross rail",
                  place(rail, 90, railRight, endApronInternalLength / 4, apronZ, false)),
        NamedPart("top-near-outer", "front outer top plank",
                  place(topOuter, 0, 0, -2 * topWidth, frameZ, false)),
        NamedPart("top-near-inner", "front inner top plank",
                  place(topInner, 0, 0, -topWidth, frameZ, false)),
        NamedPart("top-far-inner", "back inner top plank",
                  place(topInner, 0, 0, 0, frameZ, false)),
        NamedPart("top-far-outer", "back outer top plank",
                  moved(mirrorYAbout(topOuter, topWidth), 0, 0, frameZ)),
    ];

    // One wedge in each end-apron tenon, knocked in from the outside.
    static struct WedgeEnd
    {
        string label;
        double x;
        double turn;
    }
    foreach (end_; [WedgeEnd("left", left, 90), WedgeEnd("right", right, 270)])
    {
        immutable sign = end_.turn == 270 ? -1.0 : 1.0;
        immutable y = -sign * endApronLength / 2;
        immutable plus = end_.turn == 270 ? "near" : "far";
        immutable minus = end_.turn == 270 ? "far" : "near";
        out_ ~= NamedPart(
            "wedge-end-" ~ end_.label ~ "-" ~ plus,
            plus ~ " " ~ end_.label ~ " end wedge",
            place(moved(wedge, endApronLength, 0, 0),
                  end_.turn, end_.x, y, apronZ, false));
        out_ ~= NamedPart(
            "wedge-end-" ~ end_.label ~ "-" ~ minus,
            minus ~ " " ~ end_.label ~ " end wedge",
            place(mirrorXAbout(wedge, 0),
                  end_.turn, end_.x, y, apronZ, false));
    }
    return out_;
}
