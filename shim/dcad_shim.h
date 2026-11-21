/* Thin C++ shim for dcad.
 *
 * The library binds OCCT directly with D's extern(C++). This shim exists only
 * for the few things extern(C++) cannot express:
 *   - inline OCCT accessors with no out-of-line symbol (gp_Pnt::X, IsNull, ...)
 *   - C++ exceptions, which LDC cannot catch reliably from D
 *   - shape lifetime helpers (OCCT shapes are refcounted value objects)
 *
 * Every fallible function returns 0 on success and -1 on failure; the reason
 * is available from dcad_last_error().
 */
#ifndef DCAD_SHIM_H
#define DCAD_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

const char *dcad_last_error(void);

/* Inline OCCT accessors ------------------------------------------------ */
int   dcad_shape_is_null(const void *shape);
int   dcad_shape_type(const void *shape);   /* TopAbs_ShapeEnum as int */
void  dcad_point_xyz(const void *pnt, double *xyz);
void  dcad_vec_xyz(const void *vec, double *xyz);

/* Shape lifetime ------------------------------------------------------- */
void *dcad_shape_clone(const void *shape);  /* new TopoDS_Shape(*shape) */
void  dcad_shape_free(void *shape);

/* Selected edges/faces by index, for typed DSL selectors --------------- */
int   dcad_subshape_count(const void *shape, int shapeType);
void *dcad_subshape_at(const void *shape, int shapeType, int index); /* clone */

/* Exception-guarded versions of the operations that can throw ---------- */
int dcad_guarded_box(double dx, double dy, double dz, void **out);
int dcad_guarded_cylinder(double r, double h, void **out);
int dcad_guarded_cut(const void *a, const void *b, void **out);
int dcad_guarded_fuse(const void *a, const void *b, void **out);
int dcad_guarded_fillet(const void *shape, const int *edges, int n,
                        double radius, void **out);
int dcad_guarded_extrude(const void *profile, double height, void **out);
int dcad_guarded_step_write(const void *shape, const char *path);

/* A true circular face (gp_Circ -> edge -> wire -> face). Needed because
 * opencascade::handle<Geom_Curve> cannot be declared in extern(C++). */
int dcad_make_circle_face(double cx, double cy, double z, double r, void **out);

/* Rigid placement of a shape: optional mirror about the origin, rotation
 * about Z (degrees), then translation. mirrorMode: 0 none, 1 XZ plane
 * (y -> -y), 2 YZ plane (x -> -x). gp_Trsf has inline constructors, so this
 * lives in the shim rather than in extern(C++). */
int dcad_guarded_transform(const void *shape, int mirrorMode, double rotZDeg,
                            double dx, double dy, double dz, void **out);

/* A TopoDS_Compound holding the given shapes, with no boolean operation. */
int dcad_make_compound(const void **shapes, int n, void **out);

/* Measurements --------------------------------------------------------- */
double dcad_volume(const void *shape);
void   dcad_bbox(const void *shape, double *sixDoubles);

#ifdef __cplusplus
}
#endif
#endif
