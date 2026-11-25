/**
 * Take-apart keyframes for the joint.
 *
 * The host interpolates between frames at a normalised time t in [0,1], then
 * loops. The first and last frames match so the loop has no jump.
 */
module motion;

import daimochi_util : NamedPart, moved;

alias Pose = double[3][string];

/// Part B slides off the tenon in +X; the komisen lifts out in +Y/+Z.
Pose[] allPoses()
{
    Pose exploded = [
        "part-a": [0.0,   0.0,   0.0],
        "part-b": [300.0, 0.0,   0.0],
        "key":    [0.0, 140.0, 280.0],
    ];
    Pose closed = [
        "part-a": [0.0, 0.0, 0.0],
        "part-b": [0.0, 0.0, 0.0],
        "key":    [0.0, 0.0, 0.0],
    ];
    return [exploded, closed, exploded];
}

/// Apply an offset pose to the three closed-pose parts.
NamedPart[] posedParts(NamedPart[] closed, Pose pose)
{
    NamedPart[] result;
    foreach (part; closed)
    {
        auto offset = pose[part.id];
        result ~= NamedPart(part.id, part.name,
                            moved(part.shape, offset[0], offset[1], offset[2]));
    }
    return result;
}
