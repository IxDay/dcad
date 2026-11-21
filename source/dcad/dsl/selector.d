/**
 * Typed selectors. CadQuery's ">Z" / "|X" strings become enums, so a typo is
 * a compile error instead of a silent no-op.
 */
module dcad.dsl.selector;

enum FaceSelector
{
    top,
    bottom,
    front,
    back,
    left,
    right,
    all
}

enum EdgeSelector
{
    all,
    vertical,
    horizontal,
    circular
}

enum Axis
{
    x,
    y,
    z
}

enum Direction
{
    positive,
    negative
}
