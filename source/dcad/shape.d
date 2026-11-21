/**
 * Owning wrapper around an OCCT TopoDS_Shape.
 *
 * OCCT shapes are refcounted value objects; the clone/free pair in the shim
 * gives them a simple lifetime that D's GC can finalise.
 */
module dcad.shape;

import std.string : fromStringz;
import dcad.occt.topology;
import dcad.occt.types : TopAbs_ShapeEnum;

class DcadException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Translate a shim status code into a D exception with OCCT's error message.
void checkOcct(int status, string operation)
{
    if (status == 0)
        return;
    const msg = fromStringz(dcad_last_error()).idup;
    throw new DcadException(operation ~ " failed" ~ (msg.length ? ": " ~ msg : ""));
}

final class Shape
{
    private TopoDS_Shape* _native;

    this(ref const TopoDS_Shape native)
    {
        _native = cast(TopoDS_Shape*) dcad_shape_clone(cast(const(void)*)&native);
        if (_native is null)
            checkOcct(-1, "shape clone");
    }

    ~this()
    {
        if (_native !is null)
        {
            dcad_shape_free(_native);
            _native = null;
        }
    }

    /// Address of the underlying C++ object, for extern(C++) calls.
    ref const(TopoDS_Shape) native() @trusted
    {
        return *_native;
    }

    bool isNull() const @trusted
    {
        return dcad_shape_is_null(_native) != 0;
    }

    TopAbs_ShapeEnum type() const @trusted
    {
        return cast(TopAbs_ShapeEnum) dcad_shape_type(_native);
    }

    int count(TopAbs_ShapeEnum what) const @trusted
    {
        return dcad_subshape_count(_native, cast(int) what);
    }

    Shape subshape(TopAbs_ShapeEnum what, int index) @trusted
    {
        auto p = dcad_subshape_at(_native, cast(int) what, index);
        if (p is null)
            throw new DcadException("no such subshape");
        auto result = new Shape(*cast(TopoDS_Shape*) p);
        dcad_shape_free(p);
        return result;
    }

    double volume() const @trusted
    {
        return dcad_volume(_native);
    }

    /// xmin,ymin,zmin,xmax,ymax,zmax
    double[6] bounds() const @trusted
    {
        double[6] b;
        dcad_bbox(_native, b.ptr);
        return b;
    }
}
