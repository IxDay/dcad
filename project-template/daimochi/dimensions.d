/**
 * Millimetre dimensions of daimochi-tsugi, scaled from the reference sheet.
 * The two beams are 120 x 120 mm; the komisen is 30 x 30 mm in section.
 */
module dimensions;

/// Beam cross-section.
enum double beamSize = 120.0;

/// Full length of each beam along X.
enum double beamLength = 450.0;

/// The 50 mm shelf that carries the upper half of the joint.
enum double shelfDepth = 50.0;

/// Mortise / tenon height band (30..90 mm on the beam).
enum double tenonBottom = 30.0;
enum double tenonTop = 90.0;

/// Komisen section and assembled centre.
enum double keyWidth = 30.0;
enum double keyCentreY = 60.0;
enum double keyHeight = 175.0;
