/**
 * OpenGL 3D viewport: render-to-texture (FBO) with a mesh VBO and simple
 * directional shading. Orbit/pan/zoom camera included (Phase 3, since a
 * static triangle is useless for inspecting CAD shapes).
 */
module gui.viewport;

import std.math : sin, cos, sqrt, PI;
import std.stdio : stderr;

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
varying vec3 vNormal;
void main()
{
    vNormal = aNormal;
    gl_Position = uProj * uView * vec4(aPosition, 1.0);
}
VS";

private enum fragmentShaderSrc = q"FS
#version 120
varying vec3 vNormal;
void main()
{
    vec3 n = normalize(vNormal);
    vec3 light = normalize(vec3(0.4, 0.7, 1.0));
    float diff = max(dot(n, light), 0.0);
    // Brocanth primary #625afa, kept dark enough to read on the light pane.
    vec3 base = vec3(0.384, 0.353, 0.980);
    vec3 col = base * (0.55 + 0.45 * diff);
    gl_FragColor = vec4(col, 1.0);
}
FS";

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
    uint program;
    int projLoc;
    int viewLoc;
    int posLoc;
    int normLoc;
    MeshGpu mesh;
    bool diagnosticsDone;

    int width = 64;
    int height = 64;

    // camera state
    float yaw = 0.7f;
    float pitch = 0.5f;
    float distance = 200f;
    float[3] target = [0, 0, 0];
    bool cameraInitialized;

public:
    this()
    {
        initGL();
    }

    ~this()
    {
        clearMesh();
        if (depthRb) glDeleteRenderbuffers(1, &depthRb);
        if (colorTex) glDeleteTextures(1, &colorTex);
        if (fbo) glDeleteFramebuffers(1, &fbo);
        if (program) glDeleteProgram(program);
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

        glGenBuffers(1, &mesh.posVbo);
        glBindBuffer(GL_ARRAY_BUFFER, mesh.posVbo);
        glBufferData(GL_ARRAY_BUFFER, m.triangles * 9 * float.sizeof,
                     m.vertices, GL_STATIC_DRAW);

        glGenBuffers(1, &mesh.normVbo);
        glBindBuffer(GL_ARRAY_BUFFER, mesh.normVbo);
        glBufferData(GL_ARRAY_BUFFER, m.triangles * 9 * float.sizeof,
                     m.normals, GL_STATIC_DRAW);

        mesh.vertexCount = m.triangles * 3;

        // Compute bounds for camera framing.
        float[3] lo = [1e30f, 1e30f, 1e30f];
        float[3] hi = [-1e30f, -1e30f, -1e30f];
        for (int i = 0; i < mesh.vertexCount; ++i)
            for (int k = 0; k < 3; ++k)
            {
                const v = m.vertices[i * 3 + k];
                if (v < lo[k]) lo[k] = v;
                if (v > hi[k]) hi[k] = v;
            }
        for (int k = 0; k < 3; ++k)
            mesh.center[k] = (lo[k] + hi[k]) / 2;
        float maxSpan = 0;
        for (int k = 0; k < 3; ++k)
        {
            const span = hi[k] - lo[k];
            if (span > maxSpan) maxSpan = span;
        }
        mesh.radius = maxSpan > 0 ? maxSpan / 2 : 1;

        if (!cameraInitialized)
        {
            target = mesh.center;
            distance = mesh.radius * 3.2f + 10;
            cameraInitialized = true;
        }
        return m.triangles;
    }

    /// Remove the current mesh (used when a script fails, to avoid a stale render).
    void clearMesh()
    {
        if (mesh.posVbo) glDeleteBuffers(1, &mesh.posVbo);
        if (mesh.normVbo) glDeleteBuffers(1, &mesh.normVbo);
        mesh = MeshGpu.init;
    }

    bool hasMesh() const { return mesh.vertexCount > 0; }

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

    void resetCamera()
    {
        if (!cameraInitialized) return;
        target = mesh.center;
        distance = mesh.radius * 3.2f + 10;
        yaw = 0.7f;
        pitch = 0.5f;
    }

    /// Render into the FBO. `w`/`h` are in framebuffer pixels.
    void render(int w, int h)
    {
        if (w < 1 || h < 1) return;
        if (w != width || h != height)
        {
            width = w;
            height = h;
            resizeTargets();
        }
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glViewport(0, 0, width, height);
        // Brocanth muted grey #f6f8fa -- same light palette as the UI chrome.
        glClearColor(0.965f, 0.973f, 0.980f, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);

        if (mesh.vertexCount > 0)
        {
            const aspect = cast(float) width / height;
            auto proj = perspective(0.8f, aspect, 0.1f,
                                    max(distance * 10, 1000f));
            const cp = cos(pitch);
            float[3] eye = [
                target[0] + distance * cp * cos(yaw),
                target[1] + distance * cp * sin(yaw),
                target[2] + distance * sin(pitch)
            ];
            auto view = lookAt(eye, target, [0f, 0f, 1f]);
            auto mvp = multiply(proj, view);

            glUseProgram(program);
            glUniformMatrix4fv(projLoc, 1, GL_FALSE, proj.ptr);
            glUniformMatrix4fv(viewLoc, 1, GL_FALSE, view.ptr);

            glBindBuffer(GL_ARRAY_BUFFER, mesh.posVbo);
            glVertexAttribPointer(posLoc, 3, GL_FLOAT, GL_FALSE, 0, null);
            glEnableVertexAttribArray(posLoc);
            glBindBuffer(GL_ARRAY_BUFFER, mesh.normVbo);
            glVertexAttribPointer(normLoc, 3, GL_FLOAT, GL_FALSE, 0, null);
            glEnableVertexAttribArray(normLoc);

            glDrawArrays(GL_TRIANGLES, 0, mesh.vertexCount);

            glDisableVertexAttribArray(posLoc);
            glDisableVertexAttribArray(normLoc);
        }

        if (!diagnosticsDone)
        {
            diagnosticsDone = true;
            logDiagnostics();
        }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

private:
    static float max(float a, float b) { return a > b ? a : b; }

    void initGL()
    {
        program = createProgram(vertexShaderSrc, fragmentShaderSrc);
        projLoc = glGetUniformLocation(program, "uProj");
        viewLoc = glGetUniformLocation(program, "uView");
        posLoc = glGetAttribLocation(program, "aPosition");
        normLoc = glGetAttribLocation(program, "aNormal");
        stderr.writefln("viewport: program=%u proj=%d view=%d pos=%d norm=%d",
                        program, projLoc, viewLoc, posLoc, normLoc);
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
        glGetProgramiv(program, 0x8B82, &linked);   // GL_LINK_STATUS
        char[2048] log = 0;
        int logLen;
        glGetProgramInfoLog(program, log.length, &logLen, log.ptr);
        stderr.writefln("viewport: linked=%d log=%s", linked,
                        logLen > 0 ? fromStringz(log.ptr) : "(none)");

        stderr.writefln("viewport: fbo=%u tex=%u depth=%u verts=%d size=%dx%d",
                        fbo, colorTex, depthRb, mesh.vertexCount, width, height);

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
