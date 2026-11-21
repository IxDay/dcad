/**
 * A small Workplane-style fluent builder.
 *
 * Each step returns a new Workplane value; the OCCT objects are owned by
 * Shape instances so intermediate results cannot dangle. Selectors are enums
 * rather than CadQuery's string expressions.
 */
module dcad.dsl.workplane;

import std.math : abs, sqrt, PI, cos, sin;
import std.string : toStringz;

import dcad.shape : Shape, DcadException, checkOcct;
import dcad.occt.topology;
import dcad.occt.math : gp_Pnt, gp_Vec, pnt, vec;
import dcad.occt.prim : BRepPrimAPI_MakePrism;
import dcad.occt.builder : BRepBuilderAPI_MakePolygon, BRepBuilderAPI_MakeFace;
import dcad.dsl.selector : FaceSelector, EdgeSelector;
import dcad.occt.types : TopAbs_ShapeEnum;

extern(C) nothrow @nogc
{
    int dcad_guarded_box(double dx, double dy, double dz, void** out_);
    int dcad_guarded_cylinder(double r, double h, void** out_);
    int dcad_guarded_cut(const(void)* a, const(void)* b, void** out_);
    int dcad_guarded_fillet(const(void)* shape, const(int)* edges, int n,
                            double radius, void** out_);
    int dcad_guarded_extrude(const(void)* profile, double height, void** out_);
    int dcad_guarded_step_write(const(void)* shape, const(char)* path);
    int dcad_make_circle_face(double cx, double cy, double z, double r, void** out_);
}

struct Workplane
{
    Shape shape;
    FaceSelector faceSelection = FaceSelector.top;
    EdgeSelector edgeSelection = EdgeSelector.all;

private:
    double[3] _origin;          /// centre of the selected working face
    double[3][] _profile;       /// pending sketch, absolute XY coordinates
    double _profileZ;
    bool _circle;               /// true when the sketch is a true circle
    double _circleRadius;

public:
    /// Start a new model.
    static Workplane create()
    {
        return Workplane();
    }

    /// Make a box with one corner at the origin.
    Workplane box(double length, double width, double height)
    {
        void* out_;
        checkOcct(dcad_guarded_box(length, width, height, &out_), "box");
        return withNativeShape(out_);
    }

    /// Make a cylinder standing on the XY plane.
    Workplane cylinder(double radius, double height)
    {
        void* out_;
        checkOcct(dcad_guarded_cylinder(radius, height, &out_), "cylinder");
        return withNativeShape(out_);
    }

    /// Select a face; later sketches are centred on it.
    Workplane faces(FaceSelector selection)
    {
        auto wp = this;
        wp.faceSelection = selection;
        wp._origin = faceCentre(selection);
        return wp;
    }

    /// Select which edges a following fillet/chamfer operates on.
    Workplane edges(EdgeSelector selection)
    {
        auto wp = this;
        wp.edgeSelection = selection;
        return wp;
    }

    /// Add a circular sketch to the current working plane.
    Workplane circle(double radius, int segments = 32)
    {
        auto wp = this;
        wp._profile = null;
        wp._profileZ = _origin[2] - 0.01;
        wp._circle = true;
        wp._circleRadius = radius;
        foreach (i; 0 .. segments)
        {
            const a = 2.0 * PI * i / segments;
            wp._profile ~= [_origin[0] + radius * cos(a),
                            _origin[1] + radius * sin(a), wp._profileZ];
        }
        return wp;
    }

    /// Add a rectangular sketch centred on the current working plane.
    Workplane rect(double width, double height)
    {
        auto wp = this;
        wp._circle = false;
        wp._profile = [
            [_origin[0] - width / 2, _origin[1] - height / 2, _origin[2] - 0.01],
            [_origin[0] + width / 2, _origin[1] - height / 2, _origin[2] - 0.01],
            [_origin[0] + width / 2, _origin[1] + height / 2, _origin[2] - 0.01],
            [_origin[0] - width / 2, _origin[1] + height / 2, _origin[2] - 0.01],
        ];
        return wp;
    }

    /// Extrude the pending sketch into a solid. Polygonal sketches take the
    /// direct extern(C++) path (polygon -> wire -> face -> prism); circles go
    /// through the shim because OCCT's circle edge takes a Handle(Geom_Curve).
    Workplane extrude(double height)
    {
        enforceShape();
        enforce(_profile.length >= 3 || _circle, "extrude: no sketch defined");

        auto result = makeProfileSolid(_profileZ, height);
        auto wp = this;
        wp.shape = result;
        wp._profile = null;
        wp._circle = false;
        return wp;
    }

    /// Cut the pending sketch (extruded through the whole solid) from it.
    Workplane cutThruAll()
    {
        enforceShape();
        enforce(_profile.length >= 3 || _circle, "cutThruAll: no sketch defined");

        const b = shape.bounds();
        const bottom = b[2] - 1.0;
        const top = b[5] + 1.0;

        auto tool = makeProfileSolid(bottom, top - bottom);

        void* out_;
        checkOcct(dcad_guarded_cut(cast(const(void)*)&shape.native(),
                                   cast(const(void)*)&tool.native(), &out_), "cut");
        auto wp = this;
        wp.shape = fromNative(out_);
        wp._profile = null;
        wp._circle = false;
        return wp;
    }

    /// Fillet the selected edges.
    Workplane fillet(double radius)
    {
        enforceShape();
        auto indices = selectedEdges();
        enforce(indices.length > 0, "fillet: no edges selected");
        void* out_;
        checkOcct(dcad_guarded_fillet(cast(const(void)*)&shape.native(),
                                      indices.ptr, cast(int) indices.length,
                                      radius, &out_), "fillet");
        auto wp = this;
        wp.shape = fromNative(out_);
        return wp;
    }

    void exportStep(string path)
    {
        enforceShape();
        checkOcct(dcad_guarded_step_write(cast(const(void)*)&shape.native(),
                                          path.toStringz), "STEP export");
    }

private:
    static void enforce(bool condition, lazy string message)
    {
        if (!condition)
            throw new DcadException(message);
    }

    void enforceShape()
    {
        enforce(shape !is null, "operation requires a shape");
    }

    static Shape fromNative(void* p)
    {
        auto s = new Shape(*cast(TopoDS_Shape*) p);
        dcad_shape_free(p);
        return s;
    }

    /// Build a solid from the current sketch: face -> prism.
    Shape makeProfileSolid(double baseZ, double height)
    {
        Shape faceShape;
        if (_circle)
        {
            void* p;
            checkOcct(dcad_make_circle_face(_origin[0], _origin[1], baseZ,
                                            _circleRadius, &p), "circle face");
            faceShape = fromNative(p);
        }
        else
        {
            auto poly = BRepBuilderAPI_MakePolygon(0);
            foreach (p; _profile)
            {
                auto gp = pnt(p[0], p[1], baseZ);
                poly.Add(gp);
            }
            poly.Close();
            auto face = BRepBuilderAPI_MakeFace(poly.Wire(), false);
            faceShape = new Shape(asShape(face.Face()));
        }

        auto direction = vec(0, 0, height);
        auto prism = BRepPrimAPI_MakePrism(asShape(faceShape.native()),
                                           direction, false, true);
        return new Shape(builtShape(prism));
    }

    static Workplane withNativeShape(void* p)
    {
        Workplane wp;
        wp.shape = fromNative(p);
        wp._origin = [0, 0, 0];
        return wp;
    }

    double[3] faceCentre(FaceSelector selection)
    {
        enforceShape();
        const b = shape.bounds();
        double[3] c = [(b[0] + b[3]) / 2, (b[1] + b[4]) / 2, b[2]];
        final switch (selection)
        {
            case FaceSelector.top:    c[2] = b[5]; break;
            case FaceSelector.bottom: c[2] = b[2]; break;
            case FaceSelector.front:  c[1] = b[1]; break;
            case FaceSelector.back:   c[1] = b[4]; break;
            case FaceSelector.left:   c[0] = b[0]; break;
            case FaceSelector.right:  c[0] = b[3]; break;
            case FaceSelector.all:    break;
        }
        return c;
    }

    int[] selectedEdges()
    {
        const n = shape.count(TopAbs_ShapeEnum.edge);
        const b = shape.bounds();
        const span = [b[3] - b[0], b[4] - b[1], b[5] - b[2]];
        const tol = 1e-4 * (span[0] + span[1] + span[2]);

        int[] result;
        double[6][] seen;
        foreach (i; 0 .. n)
        {
            auto edge = shape.subshape(TopAbs_ShapeEnum.edge, i);
            const e = edge.bounds();
            // The boolean result is a compound; TopExp_Explorer can surface
            // geometrically identical edges more than once. Deduplicate by
            // bounds before handing edge indices to OCCT.
            bool duplicate = false;
            foreach (prev; seen)
            {
                bool same = true;
                foreach (k; 0 .. 6)
                    if (abs(prev[k] - e[k]) > tol)
                        same = false;
                if (same)
                    duplicate = true;
            }
            if (duplicate)
                continue;
            seen ~= e;
            const d = [e[3] - e[0], e[4] - e[1], e[5] - e[2]];
            bool near(double x, double y) { return abs(x - y) < tol; }
            const bool atCorner =
                (near(e[0], b[0]) || near(e[0], b[3])) &&
                (near(e[1], b[1]) || near(e[1], b[4]));
            const bool vertical = d[2] > tol && d[0] < tol && d[1] < tol && atCorner;
            const bool horizontal = d[2] < tol && (d[0] > tol || d[1] > tol);
            final switch (edgeSelection)
            {
                case EdgeSelector.all:        result ~= i; break;
                case EdgeSelector.vertical:   if (vertical) result ~= i; break;
                case EdgeSelector.horizontal: if (horizontal) result ~= i; break;
                case EdgeSelector.circular:   if (!vertical && !horizontal) result ~= i; break;
            }
        }
        return result;
    }
}
