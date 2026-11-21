/* Thin C++ shim for dcad. See dcad_shim.h for the rationale. */
#include "dcad_shim.h"

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <Bnd_Box.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Builder.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Dir.hxx>
#include <gp_Trsf.hxx>
#include <GProp_GProps.hxx>
#include <Standard_Failure.hxx>
#include <STEPControl_Writer.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>

#include <exception>
#include <string>
#include <vector>

static constexpr double kPi = 3.14159265358979323846;

/* OCCT prints STEP transfer progress to stdout by default; keep script
 * output clean (the same quirk hackerscad works around). */
/* The D-side gp_* types mirror this layout exactly. */
static_assert(sizeof(gp_Pnt) == 3 * sizeof(double), "gp_Pnt layout changed");
static_assert(sizeof(gp_Vec) == 3 * sizeof(double), "gp_Vec layout changed");

static const bool g_silenced = [] {
    Message::DefaultMessenger()->ChangePrinters().Clear();
    return true;
}();

static thread_local std::string g_error;

extern "C" const char *dcad_last_error(void) { return g_error.c_str(); }

static void set_error(const char *msg) { g_error = msg ? msg : "unknown OCCT error"; }

/* Translate every C++ exception before it can cross into a D frame: LDC
 * cannot reliably catch C++ exceptions by type. */
template <typename F>
static bool guarded(F f)
{
    try {
        g_error.clear();
        f();
        return true;
    } catch (const Standard_Failure &e) {
        std::string msg = e.DynamicType() ? e.DynamicType()->Name() : "Standard_Failure";
        if (e.GetMessageString() && *e.GetMessageString())
            msg += std::string(": ") + e.GetMessageString();
        set_error(msg.c_str());
    } catch (const std::exception &e) {
        set_error(e.what());
    } catch (...) {
        set_error("unknown C++ exception");
    }
    return false;
}

static const TopoDS_Shape &shape_of(const void *p)
{
    return *static_cast<const TopoDS_Shape *>(p);
}

extern "C" int dcad_shape_is_null(const void *shape)
{
    return shape_of(shape).IsNull() ? 1 : 0;
}

extern "C" int dcad_shape_type(const void *shape)
{
    return static_cast<int>(shape_of(shape).ShapeType());
}

extern "C" void dcad_point_xyz(const void *pnt, double *xyz)
{
    const gp_Pnt &p = *static_cast<const gp_Pnt *>(pnt);
    xyz[0] = p.X();
    xyz[1] = p.Y();
    xyz[2] = p.Z();
}

extern "C" void dcad_vec_xyz(const void *vec, double *xyz)
{
    const gp_Vec &v = *static_cast<const gp_Vec *>(vec);
    xyz[0] = v.X();
    xyz[1] = v.Y();
    xyz[2] = v.Z();
}

extern "C" void *dcad_shape_clone(const void *shape)
{
    return static_cast<void *>(new TopoDS_Shape(shape_of(shape)));
}

extern "C" void dcad_shape_free(void *shape)
{
    delete static_cast<TopoDS_Shape *>(shape);
}

extern "C" int dcad_subshape_count(const void *shape, int shapeType)
{
    int n = 0;
    TopExp_Explorer ex(shape_of(shape), static_cast<TopAbs_ShapeEnum>(shapeType));
    for (; ex.More(); ex.Next())
        ++n;
    return n;
}

extern "C" void *dcad_subshape_at(const void *shape, int shapeType, int index)
{
    TopExp_Explorer ex(shape_of(shape), static_cast<TopAbs_ShapeEnum>(shapeType));
    for (int i = 0; ex.More() && i < index; ++i, ex.Next())
        ;
    if (!ex.More())
        return nullptr;
    return dcad_shape_clone(&ex.Current());
}

extern "C" int dcad_guarded_box(double dx, double dy, double dz, void **out)
{
    return guarded([&] {
        BRepPrimAPI_MakeBox mk(dx, dy, dz);
        *out = dcad_shape_clone(&mk.Shape());
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_cylinder(double r, double h, void **out)
{
    return guarded([&] {
        BRepPrimAPI_MakeCylinder mk(r, h);
        *out = dcad_shape_clone(&mk.Shape());
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_cut(const void *a, const void *b, void **out)
{
    return guarded([&] {
        BRepAlgoAPI_Cut mk(shape_of(a), shape_of(b));
        if (!mk.IsDone())
            throw Standard_Failure("boolean cut failed");
        *out = dcad_shape_clone(&mk.Shape());
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_fuse(const void *a, const void *b, void **out)
{
    return guarded([&] {
        BRepAlgoAPI_Fuse mk(shape_of(a), shape_of(b));
        if (!mk.IsDone())
            throw Standard_Failure("boolean fuse failed");
        *out = dcad_shape_clone(&mk.Shape());
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_fillet(const void *shape, const int *edges, int n,
                                    double radius, void **out)
{
    return guarded([&] {
        BRepFilletAPI_MakeFillet mk(shape_of(shape));
        for (int i = 0; i < n; ++i) {
            void *sub = dcad_subshape_at(shape, TopAbs_EDGE, edges[i]);
            if (!sub)
                throw Standard_Failure("no such edge");
            const TopoDS_Edge &e = TopoDS::Edge(*static_cast<TopoDS_Shape *>(sub));
            mk.Add(radius, e);
            dcad_shape_free(sub);
        }
        // Shape() triggers Build(); IsDone() is not meaningful before that.
        const TopoDS_Shape &result = mk.Shape();
        if (result.IsNull())
            throw Standard_Failure("fillet produced a null shape");
        *out = dcad_shape_clone(&result);
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_extrude(const void *profile, double height, void **out)
{
    return guarded([&] {
        gp_Vec dir(0, 0, height);
        BRepPrimAPI_MakePrism mk(shape_of(profile), dir);
        if (!mk.IsDone())
            throw Standard_Failure("extrude failed");
        *out = dcad_shape_clone(&mk.Shape());
    }) ? 0 : -1;
}

extern "C" int dcad_make_circle_face(double cx, double cy, double z, double r,
                                      void **out)
{
    return guarded([&] {
        gp_Ax2 axis(gp_Pnt(cx, cy, z), gp_Dir(0, 0, 1));
        gp_Circ circle(axis, r);
        BRepBuilderAPI_MakeEdge edge(circle);
        BRepBuilderAPI_MakeWire wire(edge.Edge());
        BRepBuilderAPI_MakeFace face(wire.Wire(), true);
        *out = dcad_shape_clone(&face.Face());
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_transform(const void *shape, int mirrorMode,
                                       double rotZDeg,
                                       double dx, double dy, double dz,
                                       void **out)
{
    return guarded([&] {
        // gp_Trsf composes right-to-left: build the transform in reverse
        // application order so the result is Translate * Rotate * Mirror,
        // i.e. mirror first, rotate about the origin, translate last.
        gp_Trsf t;
        t.SetTranslation(gp_Vec(dx, dy, dz));
        if (rotZDeg != 0.0) {
            gp_Trsf rot;
            rot.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)),
                            rotZDeg * kPi / 180.0);
            t.Multiply(rot);
        }
        if (mirrorMode == 1) {           // XZ plane: y -> -y
            gp_Trsf mir;
            mir.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0)));
            t.Multiply(mir);
        } else if (mirrorMode == 2) {    // YZ plane: x -> -x
            gp_Trsf mir;
            mir.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0)));
            t.Multiply(mir);
        }
        BRepBuilderAPI_Transform mk(shape_of(shape), t, Standard_True);
        *out = dcad_shape_clone(&mk.Shape());
    }) ? 0 : -1;
}

extern "C" int dcad_make_compound(const void **shapes, int n, void **out)
{
    return guarded([&] {
        TopoDS_Compound compound;
        TopoDS_Builder builder;
        builder.MakeCompound(compound);
        for (int i = 0; i < n; ++i)
            builder.Add(compound, shape_of(shapes[i]));
        *out = dcad_shape_clone(&compound);
    }) ? 0 : -1;
}

extern "C" int dcad_guarded_step_write(const void *shape, const char *path)
{
    return guarded([&] {
        STEPControl_Writer writer;
        if (writer.Transfer(shape_of(shape), STEPControl_AsIs) != IFSelect_RetDone)
            throw Standard_Failure("STEP transfer failed");
        if (writer.Write(path) != IFSelect_RetDone)
            throw Standard_Failure("STEP write failed");
    }) ? 0 : -1;
}

extern "C" double dcad_volume(const void *shape)
{
    double v = 0.0;
    guarded([&] {
        GProp_GProps props;
        BRepGProp::VolumeProperties(shape_of(shape), props);
        v = props.Mass();
    });
    return v;
}

extern "C" void dcad_bbox(const void *shape, double *sixDoubles)
{
    guarded([&] {
        Bnd_Box box;
        BRepBndLib::Add(shape_of(shape), box);
        box.Get(sixDoubles[0], sixDoubles[1], sixDoubles[2],
                sixDoubles[3], sixDoubles[4], sixDoubles[5]);
    });
}
