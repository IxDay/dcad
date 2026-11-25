# Open risks and limitations

Honest list of what was hit while getting the proof of concept working, and
what still needs a decision. Nothing here invalidates the architecture; all of
it is either handled locally or needs a follow-up.

## extern(C++) limitations actually encountered

1. **`extern(C++) struct` vs `class`.** The D spec says polymorphic C++ types
   should be D `class`es. We bind `TopoDS_*` and the builders as `struct`s so
   that `const T&` parameters mangle correctly (`ref const T`), which a D
   `class` cannot express (`ref const C` mangles as `C const* const&`, a
   reference to a *pointer*). Consequence: calls to virtual C++ methods are
   non-virtual. `Shape()` is virtual in OCCT's builder base classes, so we call
   the base implementation explicitly via `builtShape()` / `boolShape()`.
   That is correct for OCCT 7.9 (no derived class overrides `Shape()`), but it
   is a version-sensitive assumption. **Risk: medium.** Mitigation: pin the
   OCCT version range, or add a C++ shim that performs the virtual call.

2. **No zero-argument constructors for D structs.** `this();` with a body is
   rejected. Default constructors of `BRepBuilderAPI_MakePolygon`,
   `BRepBuilderAPI_MakeWire` and `STEPControl_Writer` use
   `pragma(mangle, cxxMangle!("_ZN…C1Ev", "??0…@@QEAA@XZ")) this(int dummy);`
   with a dummy argument. All bound C++ members now use `cxxMangle!` so the
   Itanium names stay unchanged on Linux/macOS and the real Microsoft names
   (including virtual-member qualifiers) are used on Windows. **Risk: low**;
   the names are pinned to OCCT 7.7–7.9.

3. **Inline OCCT methods have no out-of-line symbols.** `gp_Pnt::X()`,
   `TopoDS_Shape::IsNull()`, `TopExp_Explorer::More()` etc. are defined in
   headers. We mirror the `gp_*` value types layout-for-layout in D and put the
   rest in the shim. **Risk: medium** if a future OCCT changes `gp_*` layout;
   they are intentionally stable value types, and a static assertion against
   `sizeof(gp_Pnt)` in the shim would close this gap.

4. **C++ exceptions cannot be relied upon in D.** I verified that LDC 1.43
   compiles `catch (extern(C++) class …)` but does not actually catch a thrown
   C++ exception in this configuration. All operations that can throw
   `Standard_Failure` are therefore wrapped by the shim's `guarded()` helper.
   D exceptions must never unwind through OCCT frames. **Risk: low** while all
   entry points go through the shim; a new direct binding that throws will
   abort the process.

5. **Opaque storage size.** Every bound C++ object sits in a 512-byte D-side
   buffer. Over-allocating is safe for stack objects, but passing such a struct
   *by value* to a C++ function expecting `T` (not `const T&`) would corrupt
   the ABI. No such function is bound. **Risk: low**, but any new binding must
   use `ref const T` / pointers only.

6. **Inline destructors.** Most builder classes have no exported destructor
   symbol, so D cannot call it. OCCT's internal refcounts for builder-owned
   shapes may leak over long sessions. **Risk: medium for a long-running Phase
   3 kernel.** Fix: shim factories/destructors, or let the kernel recycle
   builders per script.

## OCCT quirks hit

* **Fillet works on edges, never faces.** `BRepFilletAPI_MakeFillet::Add`
  takes `TopoDS_Edge`; the DSL's `faces().fillet()` sugar must discover edges.
* **`IsDone()` is not meaningful before `Build()`/`Shape()` for fillets.**
  The shim checks the shape returned by `Shape()` instead.
* **Boolean results are compounds.** `TopExp_Explorer` surfaced geometrically
  duplicate edges, which made OCCT reject a fillet that added the same edge
  twice. The DSL deduplicates by bounding box before selection.
* **STEP writer prints progress to stdout**; the shim clears
  `Message::DefaultMessenger()` printers at startup.
* **`Handle(...)` is a template macro**, not expressible in `extern(C++)`.
  It blocks circular edges via `gp_Circ`, triangulation access, and STEP
  model/name editing. These are shimmed or avoided.
* **C++ default arguments** (`Message_ProgressRange()`, `ChFi3d_Rational`,
  `Standard_False`) are call-site expansions, so every overload must be
  declared with all parameters explicit.
* **C++ `bool` maps to D `bool`** in OCCT 7.9 (`Standard_Boolean` is `bool`);
  older OCCT used `unsigned int`. Pin the supported version range.

## DSL-level simplifications to replace

* Face/edge classification uses bounding boxes. It works for axis-aligned
  boxes and the examples here, but it is not a real geometric selector.
  Replace with `BRepAdaptor_Surface`/`BRepAdaptor_Curve` and typed
  `GeomAbs_*` predicates (also shimmed where Handles appear).
* The `Workplane` type is a value struct holding class references; it is not
  yet a fully immutable builder-step tree. That is fine for the PoC, but a
  dependency graph is what enables incremental rebuilds in Phase 3.
* `Shape` relies on GC finalisation; deterministic `dispose()` should be added
  before large models are processed.

## Platform status

The bindings were developed on macOS ARM64 with LDC 1.43 and OCCT 7.9.3.
macOS and Linux share the Itanium C++ ABI with Clang/LDC; Windows uses the
Microsoft ABI with MSVC-built OCCT. Five targets are built by
`.github/workflows/build.yml`: Linux x86-64/aarch64, macOS x86/ARM, and
Windows x86-64. Windows ARM64 is excluded because LDC has no Windows ARM64
toolchain or runtime libraries.

The platform-specific pieces are:

| Concern | POSIX | Windows |
|---|---|---|
| script plugin loading | `dlopen`/`dlsym` | `LoadLibrary`/`GetProcAddress` |
| scratch dir id | `getpid` | `GetCurrentProcessId` |
| C++ shim compiler | `clang++`/`g++` + `ar` | `cl` + `lib` |
| native menu | AppKit (macOS) / Xlib (Linux) | Win32 `HMENU` |

OCCT versions still need to be kept in the 7.7–7.9 range; an OCCT 8.x ABI
change would require updating the bindings.

## Recommendation on a shim layer after all

Keep it. It is ~150 lines instead of the thousands a complete C wrapper would
require, and every line corresponds to a concrete `extern(C++)` gap. Do not
generalise it into a full OCCT C API unless profiling shows D-side overhead
matters (it will not — the cost is in OCCT).
