/**
 * A coffee-table leg: a 54 mm square post with a side-apron notch, an 8 mm
 * locating tab above the aprons' seat, and a through mortise for the end-apron
 * tenon. Open this file in the GUI and press Run to preview the leg alone.
 */
module leg;

import dcad.shape : Shape;
import dimensions;
import util;

Shape build()
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
