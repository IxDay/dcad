/**
 * TopoDS_* topology types and the shim helpers used to inspect them.
 *
 * OCCT's TopoDS_Face/Edge/Wire are distinct C++ classes derived from
 * TopoDS_Shape with no extra data members, so the cast helpers are safe
 * pointer reinterpretations (the C++ TopoDS::Face() etc. are inline and
 * therefore have no linkable symbol).
 */
module dcad.occt.topology;

import dcad.occt.types : opaqueWords, TopAbs_ShapeEnum;

extern(C++) struct TopoDS_Shape
{
    void*[opaqueWords] _opaque;
}

extern(C++) struct TopoDS_Solid
{
    void*[opaqueWords] _opaque;
}

extern(C++) struct TopoDS_Face
{
    void*[opaqueWords] _opaque;
}

extern(C++) struct TopoDS_Wire
{
    void*[opaqueWords] _opaque;
}

extern(C++) struct TopoDS_Edge
{
    void*[opaqueWords] _opaque;
}

extern(C++) struct TopoDS_Vertex
{
    void*[opaqueWords] _opaque;
}

/// C++ inline downcasts are just reinterpretations of the same object layout.
ref const(TopoDS_Edge) asEdge(ref const TopoDS_Shape s) @trusted
{
    return *cast(const(TopoDS_Edge)*)&s;
}

ref const(TopoDS_Face) asFace(ref const TopoDS_Shape s) @trusted
{
    return *cast(const(TopoDS_Face)*)&s;
}

ref const(TopoDS_Wire) asWire(ref const TopoDS_Shape s) @trusted
{
    return *cast(const(TopoDS_Wire)*)&s;
}

ref const(TopoDS_Solid) asSolid(ref const TopoDS_Shape s) @trusted
{
    return *cast(const(TopoDS_Solid)*)&s;
}

ref const(TopoDS_Shape) asShape(T)(ref const T s) @trusted
{
    return *cast(const(TopoDS_Shape)*)&s;
}

/**
 * Common base of OCCT's builders. Shape() is virtual in C++, but these
 * classes do not override it, so calling the base implementation directly is
 * correct and avoids emitting a non-existent derived symbol.
 */
extern(C++) struct BRepBuilderAPI_MakeShape
{
    void*[opaqueWords] _opaque;
    ref const(TopoDS_Shape) Shape();
}

extern(C++) struct BRepAlgoAPI_Algo
{
    void*[opaqueWords] _opaque;
    ref const(TopoDS_Shape) Shape();
}

/// Access a BRepBuilderAPI builder's result via its base-class Shape().
ref const(TopoDS_Shape) builtShape(T)(ref T builder) @trusted
{
    return (*cast(BRepBuilderAPI_MakeShape*)&builder).Shape();
}

/// Access a BRepAlgoAPI boolean's result via its base-class Shape().
ref const(TopoDS_Shape) boolShape(T)(ref T builder) @trusted
{
    return (*cast(BRepAlgoAPI_Algo*)&builder).Shape();
}

/// C++ declaration for the small shim (see shim/dcad_shim.cpp).
extern(C) nothrow @nogc
{
    const(char)* dcad_last_error();
    int dcad_shape_is_null(const(void)* shape);
    int dcad_shape_type(const(void)* shape);
    void* dcad_shape_clone(const(void)* shape);
    void dcad_shape_free(void* shape);
    int dcad_subshape_count(const(void)* shape, int shapeType);
    void* dcad_subshape_at(const(void)* shape, int shapeType, int index);
    double dcad_volume(const(void)* shape);
    void dcad_bbox(const(void)* shape, double* sixDoubles);
}

bool isNull(ref const TopoDS_Shape s) @trusted
{
    return dcad_shape_is_null(&s) != 0;
}

TopAbs_ShapeEnum shapeType(ref const TopoDS_Shape s) @trusted
{
    return cast(TopAbs_ShapeEnum) dcad_shape_type(&s);
}

/// Number of direct sub-shapes of the requested type.
int countSubshapes(ref const TopoDS_Shape s, TopAbs_ShapeEnum type) @trusted
{
    return dcad_subshape_count(cast(const(void)*)&s, cast(int) type);
}
