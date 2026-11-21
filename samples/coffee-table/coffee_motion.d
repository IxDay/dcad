/**
 * Knock-down animation data, ported from motion.py / motion.go.
 *
 * This only emits motion offsets as JSON -- no viewer or mesh generation is
 * involved. Tracks reference the STEP files written by main.d so the data is
 * self-consistent with the files actually produced here.
 */
module coffee_motion;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : array;
import std.file : write;
import std.json;

alias Pose = double[3][string];

immutable double lift = 60.0;
immutable double wedgesOut = 75.0;
immutable double sidesOut = 80.0;
immutable double apronsUp = 90.0;

immutable double[2][string] plankPaths = [
    "top-near-outer": [-160.0, 200.0],
    "top-near-inner": [-40.0, 260.0],
    "top-far-inner":  [40.0, 260.0],
    "top-far-outer":  [160.0, 200.0],
];

enum string[] wedgeIDs = [
    "wedge-end-left-near", "wedge-end-left-far",
    "wedge-end-right-near", "wedge-end-right-far",
];

private Pose addOffsets(Pose a, Pose b)
{
    auto result = a.dup;
    foreach (id, delta; b)
    {
        if (auto existing = id in result)
        {
            foreach (k; 0 .. 3)
                (*existing)[k] += delta[k];
        }
        else
            result[id] = [delta[0], delta[1], delta[2]];
    }
    return result;
}

private Pose[] frameSteps()
{
    Pose wedges;
    foreach (id; wedgeIDs)
    {
        immutable x = canFind(id, "-left-") ? -wedgesOut : wedgesOut;
        wedges[id] = [x, 0, 0];
    }

    Pose sides = [
        "leg-near-left":   [0.0, -sidesOut, 0.0],
        "leg-near-right":  [0.0, -sidesOut, 0.0],
        "apron-side-near": [0.0, -sidesOut, 0.0],
        "leg-far-left":    [0.0, sidesOut, 0.0],
        "leg-far-right":   [0.0, sidesOut, 0.0],
        "apron-side-far":  [0.0, sidesOut, 0.0],
    ];

    Pose aprons = [
        "apron-side-near": [0.0, 0.0, apronsUp],
        "apron-side-far":  [0.0, 0.0, apronsUp],
    ];

    return [wedges, sides, aprons];
}

private string[] sortedPlankIDs()
{
    string[] ids;
    foreach (id, _; plankPaths)
        ids ~= id;
    return ids.sort.array;
}

private Pose[] stages()
{
    auto planks = sortedPlankIDs();
    Pose[] result;
    result.reserve(3 + frameSteps().length);
    foreach (k; 0 .. 3)
    {
        Pose stage;
        foreach (id; planks)
        {
            immutable path = plankPaths[id];
            final switch (k)
            {
                case 0: stage[id] = [0.0, 0.0, lift]; break;
                case 1: stage[id] = [0.0, 0.0, path[1]]; break;
                case 2: stage[id] = [0.0, path[0], path[1]]; break;
            }
        }
        result ~= stage;
    }

    Pose last;
    foreach (id, pose; result[$ - 1])
        last[id] = [pose[0], pose[1], pose[2]];
    foreach (step; frameSteps())
    {
        last = addOffsets(last, step);
        Pose copy;
        foreach (id, pose; last)
            copy[id] = [pose[0], pose[1], pose[2]];
        result ~= copy;
    }
    return result;
}

private Pose[] poses()
{
    Pose[] opening = [Pose.init];
    opening ~= stages();
    Pose[] result = opening.dup;
    for (auto i = opening.length - 1; i > 0; --i)
        result ~= opening[i - 1];
    return result;
}

void writeAnimation(string path)
{
    auto allPoses = poses();
    string[] ids;
    foreach (pose; allPoses)
        foreach (id, _; pose)
            if (!ids.idIndexOf(id))
                ids ~= id;
    ids = ids.sort.array;

    JSONValue[] tracks;
    foreach (id; ids)
    {
        JSONValue[] times;
        JSONValue[] values;
        foreach (i, pose; allPoses)
        {
            times ~= JSONValue(cast(long) i);
            double[3] t = [0.0, 0.0, 0.0];
            if (auto found = id in pose)
                t = *found;
            values ~= JSONValue([JSONValue(t[0]), JSONValue(t[1]), JSONValue(t[2])]);
        }
        tracks ~= JSONValue([JSONValue(id ~ ".step"), JSONValue("t"),
                             JSONValue(times), JSONValue(values)]);
    }

    auto doc = JSONValue.emptyObject;
    doc["name"] = JSONValue("table");
    doc["speed"] = JSONValue(1.0);
    doc["tracks"] = JSONValue(tracks);
    write(path, toJSON(doc, true) ~ "\n");
}

private bool idIndexOf(string[] haystack, string needle)
{
    foreach (s; haystack)
        if (s == needle)
            return true;
    return false;
}
