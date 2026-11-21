/**
 * Dimensions mirrored from dimensions.py in the platipy/coffee-table project.
 * X runs along the table 0..1400, Y across it centred on 0, Z up from the floor.
 */
module coffee_dimensions;

import std.math : floor;
import coffee_util : fromNative, transform;
import dcad.shape : Shape, checkOcct;

extern(C) nothrow @nogc
{
    int dcad_guarded_box(double dx, double dy, double dz, void** out_);
}

enum double totalLength = 1400.0;
enum double totalWidth  = 600.0;
enum double totalHeight = 370.0;

enum double topWidth  = 150.0;
enum double topLength = totalLength;
enum double topHeight = 28.0;

enum double anchor = 8.0;
// The top seats at 334 and the legs' 8 mm tabs enter its underside, so the
// table stands 8 mm lower than totalHeight.
enum double tableHeight = totalHeight - anchor;

enum double legWidth  = 54.0;
enum double legLength = 54.0;
enum double legHeight = totalHeight - topHeight;

enum double legMarginSide = 50.0;
enum double legInset      = 30.0;

enum double sideApronMarginEnd = 30.0;
enum double sideApronWidth     = 20.0;
enum double sideApronHeight    = 64.0;
enum double sideApronLength    = totalLength - 2 * sideApronMarginEnd;
enum double sideApronOffset    = totalWidth / 2 - legInset - legWidth / 2;

enum double transversalRise = anchor;

enum double endApronWidth          = 20.0;
enum double endApronHeight         = 64.0;
enum double endApronLength         = totalWidth - 2 * legInset - 2 * legWidth;
enum double endApronInternalLength = 2 * (sideApronOffset - sideApronWidth / 2);
enum double endApronTenonWidth     = endApronWidth - 2 * 3;
enum double endApronTenonHeight    = endApronHeight - 20;
enum double endApronTenonStick     = 16.0;
enum double endApronTenonSlotOut   = -endApronTenonStick / 2;
enum double endApronTenonStickMarg = 12.0;
enum double endApronTenonLength    = legWidth + endApronTenonSlotOut +
                                     endApronTenonStick + endApronTenonStickMarg;

enum double legApronAnchor = 3.0;
enum double legNotchWidth  = sideApronWidth - 2 * legApronAnchor;

enum double wedgeTip    = 4.0;
enum double wedgeRise   = 10.0;
enum double wedgeLength = 44.0;
enum double wedgeHeight = endApronTenonStick * 1.5;

// frameZ is the aprons' and top's seat; apronZ is the aprons' centre line.
enum double frameZ  = legHeight - anchor;
enum double apronZ  = frameZ - sideApronHeight / 2;
enum double frameFY = -totalWidth / 2;

/// Outside leg positions.
double[2] legX()
{
    return [legMarginSide + legWidth / 2,
            topLength - legMarginSide - legWidth / 2];
}

/// Four shared x anchors. dimensions.py wraps both values in int(); keep the
/// truncation, it shifts the inner rail centres by a third of a millimetre.
double[4] apronAnchors()
{
    immutable external = floor(legMarginSide + legWidth / 2);
    immutable internal = floor((topLength - 2 * external) / 3 + external);
    return [external, internal, topLength - internal, topLength - external];
}

/// Axis-aligned solid from its minimum and maximum corners.
Shape block(double x0, double x1, double y0, double y1, double z0, double z1)
{
    void* p;
    checkOcct(dcad_guarded_box(x1 - x0, y1 - y0, z1 - z0, &p), "box");
    // dcad_guarded_box makes (0,0,0)..(dx,dy,dz), so translating by the
    // minimum corner puts it at the requested bounds.
    return transform(fromNative(p), 0, 0, x0, y0, z0);
}
