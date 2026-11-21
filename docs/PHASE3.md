# Phase 3: iteration and preview architecture (design only)

The kernel must stay resident. Recompiling OCCT-backed code or relaunching a
process on every edit is too slow; the fast-changing part is the *script*, not
the binding layer. No irreversible choice is made here.

## Constraints derived from Phases 1–2

* OCCT has process-global state (messenger, static tables, `Handle` refcounts)
  and is not safe to load/unload repeatedly. Keep it in one long-lived host.
* Scripts are D code using the typed DSL; we want to keep compile-time checks.
* A preview needs a mesh, not B-rep; `BRepMesh_IncrementalMesh` plus a shimmed
  triangulation reader is the likely path.
* The D ↔ C++ boundary must be narrow and stable: `extern(C)` data structures
  for the host/plugin protocol, `extern(C++)` only inside the kernel.

## Options

### A. Single process, script as a D shared library (hot reload)

Compile the edited script with LDC into a versioned `.so` (`model_<rev>.so`)
exposing a C ABI entry point, `dlopen` it in the host, call it, then `dlclose`
the previous revision. OCCT and the DSL live in the host; the plugin contains
only model code.

* Pros: keeps full static typing; small scripts compile in well under a second
  with LDC; no second language; kernel state (caches, mesher) stays warm.
* Cons: reload correctness (global constructors, GC roots, typeinfo identity
  across D SOs) needs care; debug info and stack traces across the boundary
  are awkward; unloadable plugins must not keep references into OCCT after
  `dlclose`.
* Verdict: **best fit for the static-typing goal**. Prototype first.

### B. Persistent kernel process + thin client (IPC)

Host owns OCCT and listens on a local socket. The editor/client sends a script
revision or a serialised builder-step graph; the host returns B-rep/mesh
handles and status. Option A can run inside this host.

* Pros: crash isolation (a bad script kills a worker, not the UI); language-
  agnostic clients; natural place for a mesh cache and for multiple open
  documents; works with a browser/WebGL preview.
* Cons: need a wire format for geometry/mesh; more plumbing; per-edit IPC
  latency (small compared with boolean operations).
* Verdict: **likely the eventual shape**, but build it after the in-process
  loop works so we can measure where time actually goes.

### C. Embedded interpreter (Lua) calling bound OCCT

Ship a Lua (or similar) VM in the host; scripts are interpreted, so edits are
instant.

* Pros: fastest edit loop; no compiler in the user's loop; easy to sandbox.
* Cons: loses static typing — the exact problem this project sets out to
  solve; needs a second binding surface over the DSL; numeric/unit semantics
  diverge from D.
* Verdict: keep as a fallback for interactive tuning of parameters, never as
  the primary authoring language.

### D. Incremental D recompilation without a plugin boundary

Rebuild the whole executable with LDC and restart it, relying on a warm disk
cache and incremental linking.

* Pros: trivial to implement.
* Cons: still loses kernel state and reloads OCCT; the slowest option.
* Verdict: only as a baseline to measure against.

## Suggested prototype (not committed)

1. Split `dcad` into a host library (bindings + DSL + mesher) and a tiny C ABI:
   `int dcad_run(const(char)* scriptSo, DcadResult* out)`.
2. `Workplane` gains a serialisable step graph, so a client can send just the
   changed tail of a model instead of re-executing all of it. This is where
   the "immutable builder steps" idea from Phase 2 pays off.
3. Preview mesh is produced once per accepted revision and cached by step-graph
   hash; the transport is a flat array of floats/indices (same shape as the
   `hc_mesh` structure in the reference project `hackerscad`).
4. Measure edit-to-preview latency for a box-with-holes model before choosing
   between A and B. Add a worker process only if script crashes are a real
   problem in practice.

## Open questions

* D SO typeinfo/GC interaction under LDC — needs a spike before committing to
  option A.
* Should the script graph be the wire format (option B), or just the `.so` path
  plus a result handle?
* Incremental boolean rebuilds: OCCT has limited shape-history support; how
  much of the graph can actually be reused is unknown.
