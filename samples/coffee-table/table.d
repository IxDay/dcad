/**
 * The coffee-table assembly: imports every element and the motion data.
 *
 * Open this file in the GUI and press Run for the full animated table. The
 * standalone main below is compiled with -d-version=Standalone to write the
 * same STEP files and keyframe JSON; the GUI never sees it.
 */
module table;

import std.stdio : writefln, writeln;
import std.file : mkdirRecurse;
import std.math : abs;

import dcad.shape : Shape;
import dimensions;
import util : NamedPart, compound, exportStep, moved, mirrorXAbout,
             mirrorYAbout, place;
import motion : allPoses, writeAnimation;

import leg : makeLeg = build;
import side_apron : makeSideApron = build;
import end_apron : makeEndApron = build;
import cross_rail : makeRail = build;
import top_outer : makeTopOuter = build;
import top_inner : makeTopInner = build;
import wedge : makeWedge = build;

/// All eighteen timbers in the closed pose, with stable ids for the animation.
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
    auto rail = makeRail();
    auto topOuter = makeTopOuter();
    auto topInner = makeTopInner();
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

/// Module-style GUI entry point: the closed assembly.
Shape dcadMain()
{
    Shape[] shapes;
    foreach (p; tableParts())
        shapes ~= p.shape;
    return compound(shapes);
}

/// Module-style GUI animation hooks.
NamedPart[] dcadParts()
{
    return tableParts();
}

double[3][string][] dcadPoses()
{
    return allPoses();
}

version (Standalone)
void main()
{
    auto parts = tableParts();
    mkdirRecurse("table");

    foreach (p; parts)
    {
        exportStep(p.shape, "table/" ~ p.id ~ ".step");
        immutable b = p.shape.bounds();
        writefln("%-20s vol=%10.2f  x=[%7.2f,%7.2f] y=[%7.2f,%7.2f] z=[%6.2f,%6.2f]",
                 p.id, p.shape.volume(), b[0], b[3], b[1], b[4], b[2], b[5]);
    }

    Shape[] shapes;
    foreach (p; parts)
        shapes ~= p.shape;
    auto assembly = compound(shapes);
    exportStep(assembly, "coffee-table.step");

    immutable b = assembly.bounds();
    writefln("assembly: %d parts, %.1f x %.1f x %.1f mm, volume %.2f mm^3",
             parts.length, b[3] - b[0], b[4] - b[1], b[5] - b[2],
             assembly.volume());
    assert(parts.length == 18);
    assert(abs((b[3] - b[0]) - 1400.0) < 0.01);
    assert(abs((b[4] - b[1]) - 600.0) < 0.01);
    assert(abs((b[5] - b[2]) - 362.0) < 0.01);

    writeAnimation("table/animation.json");
    writeln("wrote table/*.step, coffee-table.step and table/animation.json");
}
