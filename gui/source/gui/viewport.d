/**
 * OpenGL 3D viewport: render-to-texture (FBO) with a mesh VBO and simple
 * directional shading. Orbit/pan/zoom camera included (Phase 3, since a
 * static triangle is useless for inspecting CAD shapes).
 */
module gui.viewport;

import std.math : sin, cos, atan, sqrt, PI;
import std.stdio : stderr;
import std.string : toStringz;
import std.process : environment;

import bindbc.opengl;
import gui.imgui : DcadMesh, dcad_mesh_shape, dcad_mesh_free;

// --- Minimal column-major 4x4 matrix helpers --------------------------------
private alias Mat4 = float[16];

private Mat4 identity()
{
    Mat4 m = 0;
    m[0] = m[5] = m[10] = m[15] = 1;
    return m;
}

private Mat4 multiply(Mat4 a, Mat4 b)
{
    Mat4 r = 0;
    for (int c = 0; c < 4; ++c)
        for (int row = 0; row < 4; ++row)
        {
            float sum = 0;
            for (int k = 0; k < 4; ++k)
                sum += a[k * 4 + row] * b[c * 4 + k];
            r[c * 4 + row] = sum;
        }
    return r;
}

private Mat4 perspective(float fovY, float aspect, float near_, float far_)
{
    Mat4 m = 0;
    const f = 1.0f / tan(fovY / 2);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far_ + near_) / (near_ - far_);
    m[11] = -1;
    m[14] = 2 * far_ * near_ / (near_ - far_);
    return m;
}

private Mat4 ortho(float halfW, float halfH, float near_, float far_)
{
    Mat4 m = 0;
    m[0] = 1 / halfW;
    m[5] = 1 / halfH;
    m[10] = -2 / (far_ - near_);
    m[14] = -(far_ + near_) / (far_ - near_);
    m[15] = 1;
    return m;
}

private Mat4 lookAt(float[3] eye, float[3] center, float[3] up)
{
    float[3] f = [center[0] - eye[0], center[1] - eye[1], center[2] - eye[2]];
    normalize(f);
    float[3] s = [f[1] * up[2] - f[2] * up[1],
                  f[2] * up[0] - f[0] * up[2],
                  f[0] * up[1] - f[1] * up[0]];
    normalize(s);
    float[3] u = [s[1] * f[2] - s[2] * f[1],
                  s[2] * f[0] - s[0] * f[2],
                  s[0] * f[1] - s[1] * f[0]];

    Mat4 m = identity();
    m[0] = s[0]; m[4] = s[1]; m[8]  = s[2];
    m[1] = u[0]; m[5] = u[1]; m[9]  = u[2];
    m[2] = -f[0]; m[6] = -f[1]; m[10] = -f[2];
    m[12] = -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]);
    m[13] = -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]);
    m[14] = f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2];
    return m;
}

private void normalize(ref float[3] v)
{
    const len = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len > 1e-8f)
    {
        v[0] /= len; v[1] /= len; v[2] /= len;
    }
}

private float tan(float x) { return sin(x) / cos(x); }

// --- Shaders (GLSL 120, compatible with macOS GL 2.1) ------------------------
private enum vertexShaderSrc = q"VS
#version 120
attribute vec3 aPosition;
attribute vec3 aNormal;
uniform mat4 uProj;
uniform mat4 uView;
uniform vec3 uOffset;
varying vec3 vNormal;
void main()
{
    vNormal = aNormal;
    gl_Position = uProj * uView * vec4(aPosition + uOffset, 1.0);
}
VS";

/// Selectable surface shading. Both programs share the vertex shader and the
/// highlight tint; only the base colour / lighting term differs.
enum ShaderMode { vscodeYellow, wood }

private enum fragmentShaderSrc = q"FS
#version 120
varying vec3 vNormal;
uniform float uHighlight;
void main()
{
    vec3 n = normalize(vNormal);
    vec3 light = normalize(vec3(0.4, 0.7, 1.0));
    float diff = max(dot(n, light), 0.0);
    // Base16 Default Light yellow (#f7ca88), the VS Code theme's yellow.
    vec3 base = vec3(0.969, 0.792, 0.533);
    vec3 col = base * (0.68 + 0.32 * diff);
    if (uHighlight > 0.5)
    {
        // VS Code selection blue, kept readable against the light canvas.
        col = mix(col, vec3(0.29, 0.62, 0.80), 0.72) + 0.06 * diff;
    }
    gl_FragColor = vec4(col, 1.0);
}
FS";

/// The wood look baked into the joinery project's GLBs by tools/export.py:
/// shade(n) = 0.60 + 0.53 * max(0, n . L), applied to the #e9c28c face colour
/// in sRGB. glTF's L is Y-up; swap Y/Z for our Z-up CAD coordinates.
private enum woodFragmentShaderSrc = q"FS
#version 120
varying vec3 vNormal;
uniform float uHighlight;
void main()
{
    vec3 n = normalize(vNormal);
    vec3 light = vec3(-0.3948, 0.2818, 0.8745);
    float k = min(1.0, 0.60 + 0.53 * max(dot(n, light), 0.0));
    vec3 col = vec3(0.9137, 0.7608, 0.5490) * k;
    if (uHighlight > 0.5)
        col = mix(col, vec3(0.29, 0.62, 0.80), 0.72) + 0.06 * k;
    gl_FragColor = vec4(col, 1.0);
}
FS";

// Lines for the OpenSCAD-style axis cross and ground grid.
private enum lineVertexShaderSrc = q"LVS
#version 120
attribute vec3 aPosition;
attribute vec3 aColor;
uniform mat4 uProj;
uniform mat4 uView;
varying vec3 vColor;
void main()
{
    vColor = aColor;
    gl_Position = uProj * uView * vec4(aPosition, 1.0);
}
LVS";

private enum lineFragmentShaderSrc = q"LFS
#version 120
varying vec3 vColor;
void main() { gl_FragColor = vec4(vColor, 1.0); }
LFS";

/// A snapshot of mesh data owned by the viewport.
private struct MeshGpu
{
    uint posVbo;
    uint normVbo;
    int vertexCount;
    float[3] center;
    float radius;
}

final class Viewport
{
private:
    uint fbo;
    uint colorTex;
    uint depthRb;
    uint[2] programs;
    int[2] projLocs;
    int[2] viewLocs;
    int[2] offsetLocs;
    int[2] highlightLocs;
    int[2] posLocs;
    int[2] normLocs;
    ShaderMode shaderMode = ShaderMode.vscodeYellow;
    uint lineProgram;
    uint guideVbo;
    int lineProjLoc;
    int lineViewLoc;
    int linePosLoc;
    int lineColorLoc;
    int guideVertexCount;
    bool showAxes = true;
    bool showGrid = true;
    bool wireframe;
    bool orthographic;
    MeshGpu mesh;
    MeshGpu[] partMeshes;
    float[3][] partOffsets;
    int highlightPart = -1;
    bool diagnosticsDone;
    bool diagnosticsEnabled;
    bool woodReady;
    bool disposed;

    int width = 64;
    int height = 64;

    // camera state
    float yaw = 0.7f;
    float pitch = 0.5f;
    float distance = 200f;
    float[3] target = [0, 0, 0];
    bool cameraInitialized;
    bool fitPending;

public:
    this()
    {
        // The first-frame GPU readback is useful when debugging a blank
        // preview, but it stalls the pipeline for several megabytes. Normal
        // launches should not pay that cost.
        diagnosticsEnabled = environment.get("DCAD_DIAGNOSTICS", "") == "1";
        initGL();
    }

    ~this()
    {
        // GL resources must be released by dispose() while the context is
        // current. A GC finalizer runs at an arbitrary time -- possibly after
        // GLFW destroyed the context -- so it must not touch GL here.
    }

    /// Release GL resources explicitly, before the window/context goes away.
    void dispose()
    {
        if (disposed) return;
        disposed = true;
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        clearMesh();
        if (depthRb) glDeleteRenderbuffers(1, &depthRb);
        if (colorTex) glDeleteTextures(1, &colorTex);
        if (fbo) glDeleteFramebuffers(1, &fbo);
        glUseProgram(0);
        foreach (p; programs) if (p) glDeleteProgram(p);
        if (lineProgram) glDeleteProgram(lineProgram);
        if (guideVbo) glDeleteBuffers(1, &guideVbo);
        depthRb = colorTex = fbo = lineProgram = guideVbo = 0;
        programs[] = 0;
    }

    /// The FBO colour texture, for display via ImGui::Image.
    void* textureID() const @trusted
    {
        return cast(void*) cast(size_t) colorTex;
    }

    /// Upload a new mesh from an OCCT shape. Returns triangle count.
    int setShape(const(void)* shapePtr, double deflection)
    {
        DcadMesh m;
        if (dcad_mesh_shape(shapePtr, deflection, &m) != 0)
            return -1;
        scope(exit) dcad_mesh_free(&m);

        if (m.triangles <= 0)
            return 0;

        clearMesh();
        mesh = upload(m);
        float[3] lo = [1e30f, 1e30f, 1e30f];
        float[3] hi = [-1e30f, -1e30f, -1e30f];
        expandBounds(lo, hi, m);
        frameCamera(lo, hi);
        return m.triangles;
    }

    /// Upload each animation part separately. One draw call per part keeps
    /// animation to a uniform update per frame -- no re-meshing or OCCT work.
    int setParts(const(void)*[] shapes, double deflection)
    {
        float[3] lo = [1e30f, 1e30f, 1e30f];
        float[3] hi = [-1e30f, -1e30f, -1e30f];
        int total;

        clearMesh();
        foreach (s; shapes)
        {
            DcadMesh m;
            if (dcad_mesh_shape(s, deflection, &m) != 0)
                continue;
            scope(exit) dcad_mesh_free(&m);
            if (m.triangles <= 0)
                continue;
            partMeshes ~= upload(m);
            partOffsets ~= [0f, 0f, 0f];
            expandBounds(lo, hi, m);
            total += m.triangles;
        }
        if (total == 0)
            return 0;
        frameCamera(lo, hi);
        return total;
    }

    /// Apply a translation per part (3 doubles each) without re-meshing.
    void setOffsets(double[] values)
    {
        foreach (i; 0 .. partOffsets.length)
            foreach (k; 0 .. 3)
            {
                immutable idx = i * 3 + k;
                partOffsets[i][k] = idx < values.length ? cast(float) values[idx] : 0;
            }
    }

    /// Remove the current mesh (used when a script fails, to avoid a stale render).
    void clearMesh()
    {
        freeGpu(mesh);
        foreach (ref p; partMeshes)
            freeGpu(p);
        partMeshes = null;
        partOffsets = null;
        highlightPart = -1;
        mesh = MeshGpu.init;
    }

    bool hasMesh() const { return mesh.vertexCount > 0 || partMeshes.length > 0; }

private:
    static MeshGpu upload(ref DcadMesh m)
    {
        MeshGpu g;
        glGenBuffers(1, &g.posVbo);
        glBindBuffer(GL_ARRAY_BUFFER, g.posVbo);
        glBufferData(GL_ARRAY_BUFFER, m.triangles * 9 * float.sizeof,
                     m.vertices, GL_STATIC_DRAW);
        glGenBuffers(1, &g.normVbo);
        glBindBuffer(GL_ARRAY_BUFFER, g.normVbo);
        glBufferData(GL_ARRAY_BUFFER, m.triangles * 9 * float.sizeof,
                     m.normals, GL_STATIC_DRAW);
        g.vertexCount = m.triangles * 3;
        return g;
    }

    static void freeGpu(ref MeshGpu g)
    {
        if (g.posVbo) glDeleteBuffers(1, &g.posVbo);
        if (g.normVbo) glDeleteBuffers(1, &g.normVbo);
        g = MeshGpu.init;
    }

    static void expandBounds(ref float[3] lo, ref float[3] hi, ref DcadMesh m)
    {
        for (int i = 0; i < m.triangles * 3; ++i)
            for (int k = 0; k < 3; ++k)
            {
                const v = m.vertices[i * 3 + k];
                if (v < lo[k]) lo[k] = v;
                if (v > hi[k]) hi[k] = v;
            }
    }

    void frameCamera(ref float[3] lo, ref float[3] hi)
    {
        for (int k = 0; k < 3; ++k)
            mesh.center[k] = (lo[k] + hi[k]) / 2;
        float maxSpan = 0;
        for (int k = 0; k < 3; ++k)
        {
            const span = hi[k] - lo[k];
            if (span > maxSpan) maxSpan = span;
        }
        mesh.radius = maxSpan > 0 ? maxSpan / 2 : 1;
        rebuildGuides(lo[2]);
        cameraInitialized = true;
        fitPending = true;
    }

    /// Grid + axis-cross geometry, rebuilt whenever a new mesh is framed.
    private void rebuildGuides(float baseZ)
    {
        float[] v;
        immutable cx = mesh.center[0];
        immutable cy = mesh.center[1];
        immutable z = baseZ - 0.5f;
        immutable ext = mesh.radius * 2.2f;
        float[3] grey = [0.72f, 0.74f, 0.76f];
        foreach (i; 0 .. 11)
        {
            immutable f = -ext + 2 * ext * i / 10.0f;
            addLine(v, [cx + f, cy - ext, z], [cx + f, cy + ext, z], grey);
            addLine(v, [cx - ext, cy + f, z], [cx + ext, cy + f, z], grey);
        }
        immutable len = mesh.radius * 1.3f;
        addLine(v, [cx, cy, z], [cx + len, cy, z], [0.80f, 0.18f, 0.18f]);
        addLine(v, [cx, cy, z], [cx, cy + len, z], [0.12f, 0.55f, 0.20f]);
        addLine(v, [cx, cy, z], [cx, cy, z + len], [0.16f, 0.40f, 0.82f]);
        addLine(v, [cx, cy, z], [cx - len, cy, z], [0.92f, 0.62f, 0.62f]);
        addLine(v, [cx, cy, z], [cx, cy - len, z], [0.62f, 0.82f, 0.65f]);

        glBindBuffer(GL_ARRAY_BUFFER, guideVbo);
        glBufferData(GL_ARRAY_BUFFER, v.length * float.sizeof,
                     v.ptr, GL_STATIC_DRAW);
        guideVertexCount = cast(int)(v.length / 6);
    }

    private static void addLine(ref float[] v, float[3] a, float[3] b,
                                float[3] c)
    {
        v ~= [a[0], a[1], a[2], c[0], c[1], c[2],
              b[0], b[1], b[2], c[0], c[1], c[2]];
    }

public:
    /// Camera input from ImGui mouse state.
    void orbit(float dx, float dy)
    {
        yaw -= dx * 0.008f;
        pitch += dy * 0.008f;
        if (pitch > 1.55f) pitch = 1.55f;
        if (pitch < -1.55f) pitch = -1.55f;
    }

    void pan(float dx, float dy)
    {
        const scale = distance * 0.002f;
        target[0] -= (cos(yaw) * dx - sin(yaw) * sin(pitch) * dy) * scale;
        target[1] -= (sin(yaw) * dx + cos(yaw) * sin(pitch) * dy) * scale;
        target[2] += cos(pitch) * dy * scale;
    }

    void zoom(float delta)
    {
        distance *= (delta > 0) ? 0.9f : 1.1f;
        if (distance < 1) distance = 1;
    }

    /// OpenSCAD-style view presets. All keep the current zoom/target.
    void setView(float newYaw, float newPitch)
    {
        yaw = newYaw;
        pitch = newPitch;
    }

    void viewIso()   { setView(0.7f, 0.5f); }
    void viewTop()   { setView(-PI / 2, 1.55f); }
    void viewBottom(){ setView(-PI / 2, -1.55f); }
    void viewFront() { setView(-PI / 2, 0); }
    void viewBack()  { setView(PI / 2, 0); }
    void viewRight() { setView(0, 0); }
    void viewLeft()  { setView(PI, 0); }

    /// Frame the whole bounding sphere for the current pane aspect ratio.
    void fitAll()
    {
        if (!cameraInitialized) return;
        target = mesh.center;
        immutable fov = 0.8f;
        immutable aspect = height > 0 ? cast(float) width / height : 1.6f;
        // Perspective needs sin() of the half-angle; orthographic uses tan().
        immutable vHalf = orthographic ? tan(fov / 2) : sin(fov / 2);
        immutable hHalf = orthographic
            ? tan(fov / 2) * aspect
            : sin(atan(tan(fov / 2) * aspect));
        immutable limiting = vHalf < hHalf ? vHalf : hHalf;
        distance = mesh.radius / limiting * 1.12f + 2f;
    }

    void resetCamera()
    {
        viewIso();
        fitAll();
    }

    // Display toggles mirrored from the preview toolbar.
    void setAxes(bool v) { showAxes = v; }
    bool axesEnabled() const { return showAxes; }
    void setGrid(bool v) { showGrid = v; }
    bool gridEnabled() const { return showGrid; }
    void setWireframe(bool v) { wireframe = v; }
    bool wireframeEnabled() const { return wireframe; }
    void setOrthographic(bool v) { orthographic = v; }
    bool orthographicEnabled() const { return orthographic; }

    /// Index of the assembly part highlighted from the parts list (-1 = none).
    void setHighlightPart(int i) { highlightPart = i; }

    /// Surface shading selected from the View > Shader menu.
    void setShaderMode(ShaderMode mode) nothrow { shaderMode = mode; }

    /// Render into the FBO. `w`/`h` are in framebuffer pixels.
    void render(int w, int h)
    {
        if (w < 1 || h < 1) return;
        if (w != width || h != height)
        {
            width = w;
            height = h;
            resizeTargets();
            // A new pane aspect can clip the model: refit whenever the canvas
            // changes size, and also after every new mesh.
            fitPending = true;
        }
        if (fitPending)
        {
            fitAll();
            fitPending = false;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glViewport(0, 0, width, height);
        // OpenSCAD-style near-white canvas.
        glClearColor(0.98f, 0.98f, 0.98f, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);

        if (mesh.vertexCount > 0 || partMeshes.length > 0)
        {
            const aspect = cast(float) width / height;
            immutable far_ = max(distance * 10, 1000f);
            Mat4 proj;
            if (orthographic)
            {
                immutable halfH = distance * tan(0.8f / 2);
                proj = ortho(halfH * aspect, halfH, 0.1f, far_);
            }
            else
                proj = perspective(0.8f, aspect, 0.1f, far_);
            const cp = cos(pitch);
            float[3] eye = [
                target[0] + distance * cp * cos(yaw),
                target[1] + distance * cp * sin(yaw),
                target[2] + distance * sin(pitch)
            ];
            auto view = lookAt(eye, target, [0f, 0f, 1f]);

            if (showAxes || showGrid)
                drawGuides(proj, view);

            immutable si = cast(int) shaderMode;
            if (si == 1 && !woodReady)
            {
                initSurfaceProgram(1, woodFragmentShaderSrc);
                woodReady = true;
            }
            glUseProgram(programs[si]);
            glUniformMatrix4fv(projLocs[si], 1, GL_FALSE, proj.ptr);
            glUniformMatrix4fv(viewLocs[si], 1, GL_FALSE, view.ptr);

            if (wireframe) glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
            if (mesh.vertexCount > 0)
            {
                float[3] zero = [0f, 0f, 0f];
                glUniform1f(highlightLocs[si], 0f);
                drawMesh(mesh, zero, si);
            }
            else
                foreach (i, ref p; partMeshes)
                {
                    glUniform1f(highlightLocs[si],
                                highlightPart == cast(int) i ? 1f : 0f);
                    drawMesh(p, partOffsets[i], si);
                }
            if (wireframe) glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);

            glDisableVertexAttribArray(posLocs[si]);
            glDisableVertexAttribArray(normLocs[si]);
        }

        if (diagnosticsEnabled && !diagnosticsDone)
        {
            diagnosticsDone = true;
            logDiagnostics();
        }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

private:
    static float max(float a, float b) { return a > b ? a : b; }

    void drawGuides(ref Mat4 proj, ref Mat4 view)
    {
        if (guideVertexCount <= 0) return;
        glUseProgram(lineProgram);
        glUniformMatrix4fv(lineProjLoc, 1, GL_FALSE, proj.ptr);
        glUniformMatrix4fv(lineViewLoc, 1, GL_FALSE, view.ptr);
        glBindBuffer(GL_ARRAY_BUFFER, guideVbo);
        enum size_t stride = 6 * float.sizeof;
        glVertexAttribPointer(linePosLoc, 3, GL_FLOAT, GL_FALSE, stride, null);
        glVertexAttribPointer(lineColorLoc, 3, GL_FLOAT, GL_FALSE, stride,
                              cast(void*) cast(size_t)(3 * float.sizeof));
        glEnableVertexAttribArray(linePosLoc);
        glEnableVertexAttribArray(lineColorLoc);
        glDrawArrays(GL_LINES, 0, guideVertexCount);
        glDisableVertexAttribArray(linePosLoc);
        glDisableVertexAttribArray(lineColorLoc);
    }

    void drawMesh(ref MeshGpu g, ref float[3] off, int si)
    {
        glUniform3f(offsetLocs[si], off[0], off[1], off[2]);
        glBindBuffer(GL_ARRAY_BUFFER, g.posVbo);
        glVertexAttribPointer(posLocs[si], 3, GL_FLOAT, GL_FALSE, 0, null);
        glEnableVertexAttribArray(posLocs[si]);
        glBindBuffer(GL_ARRAY_BUFFER, g.normVbo);
        glVertexAttribPointer(normLocs[si], 3, GL_FLOAT, GL_FALSE, 0, null);
        glEnableVertexAttribArray(normLocs[si]);
        glDrawArrays(GL_TRIANGLES, 0, g.vertexCount);
    }

    void initSurfaceProgram(int i, string fragmentSrc)
    {
        programs[i] = createProgram(vertexShaderSrc, fragmentSrc.toStringz);
        projLocs[i] = glGetUniformLocation(programs[i], "uProj");
        viewLocs[i] = glGetUniformLocation(programs[i], "uView");
        offsetLocs[i] = glGetUniformLocation(programs[i], "uOffset");
        highlightLocs[i] = glGetUniformLocation(programs[i], "uHighlight");
        posLocs[i] = glGetAttribLocation(programs[i], "aPosition");
        normLocs[i] = glGetAttribLocation(programs[i], "aNormal");
    }

    void initGL()
    {
        // Wood is only compiled when the menu selects it; most launches never
        // use it, and ANGLE's first shader compile can be noticeable.
        initSurfaceProgram(0, fragmentShaderSrc);
        stderr.writefln("viewport: shader=%u proj=%d pos=%d norm=%d "
                        ~ "(wood compiled on demand)",
                        programs[0], projLocs[0], posLocs[0], normLocs[0]);
        lineProgram = createProgram(lineVertexShaderSrc, lineFragmentShaderSrc);
        lineProjLoc = glGetUniformLocation(lineProgram, "uProj");
        lineViewLoc = glGetUniformLocation(lineProgram, "uView");
        linePosLoc = glGetAttribLocation(lineProgram, "aPosition");
        lineColorLoc = glGetAttribLocation(lineProgram, "aColor");
        glGenBuffers(1, &guideVbo);
        glGenFramebuffers(1, &fbo);
        glGenTextures(1, &colorTex);
        glGenRenderbuffers(1, &depthRb);
        resizeTargets();
    }

    void logDiagnostics()
    {
        import std.string : fromStringz;
        const ver = glGetString(0x1F02);            // GL_VERSION
        const glsl = glGetString(0x8B8C);           // GL_SHADING_LANGUAGE_VERSION
        stderr.writefln("viewport: GL=%s GLSL=%s",
                        ver ? fromStringz(ver) : "(null)",
                        glsl ? fromStringz(glsl) : "(null)");

        int linked;
        auto activeProgram = programs[cast(int) shaderMode];
        glGetProgramiv(activeProgram, 0x8B82, &linked);   // GL_LINK_STATUS
        char[2048] log = 0;
        int logLen;
        glGetProgramInfoLog(activeProgram, log.length, &logLen, log.ptr);
        stderr.writefln("viewport: linked=%d log=%s", linked,
                        logLen > 0 ? fromStringz(log.ptr) : "(none)");

        int totalVerts = mesh.vertexCount;
        foreach (p; partMeshes) totalVerts += p.vertexCount;
        stderr.writefln("viewport: fbo=%u tex=%u depth=%u verts=%d parts=%d size=%dx%d",
                        fbo, colorTex, depthRb, totalVerts,
                        partMeshes.length, width, height);

        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        auto px = new ubyte[width * height * 4];
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, px.ptr);
        int maxv;
        for (size_t i = 0; i < px.length; ++i)
            if (px[i] > maxv) maxv = px[i];
        const c = cast(size_t)(height / 2 * width + width / 2) * 4;
        stderr.writefln("viewport: center=(%d,%d,%d,%d) max=%d glerr=0x%x",
                        px[c], px[c + 1], px[c + 2], px[c + 3], maxv,
                        glGetError());
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    void resizeTargets()
    {
        glBindTexture(GL_TEXTURE_2D, colorTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        glBindRenderbuffer(GL_RENDERBUFFER, depthRb);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT,
                              width, height);

        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, colorTex, 0);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                  GL_RENDERBUFFER, depthRb);
        const status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE)
            stderr.writefln("warning: framebuffer incomplete (0x%x)", status);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    static uint compileShader(int type, const(char)* src)
    {
        uint shader = glCreateShader(type);
        glShaderSource(shader, 1, &src, null);
        glCompileShader(shader);
        int ok;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
        if (!ok)
        {
            char[4096] log = 0;
            int len;
            glGetShaderInfoLog(shader, log.length, &len, log.ptr);
            stderr.writefln("shader error: %s", log.ptr);
        }
        return shader;
    }

    static uint createProgram(const(char)* vs, const(char)* fs)
    {
        uint v = compileShader(GL_VERTEX_SHADER, vs);
        uint f = compileShader(GL_FRAGMENT_SHADER, fs);
        uint p = glCreateProgram();
        glAttachShader(p, v);
        glAttachShader(p, f);
        glLinkProgram(p);
        glDeleteShader(v);
        glDeleteShader(f);
        return p;
    }
}
