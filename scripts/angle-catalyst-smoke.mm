// Original PearSilicon probe. Creates no window and sends no input.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: angle-catalyst-smoke /path/to/libEGL.dylib\n"); return 2; }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "ANGLE load failed: %s\n", dlerror()); return 2; }
    auto getProc = (PFNEGLGETPROCADDRESSPROC)dlsym(library, "eglGetProcAddress");
    if (!getProc) return 3;
#define EGL_FUNCTION(name, type) auto name = (type)dlsym(library, #name); if (!name) return 3
    EGL_FUNCTION(eglInitialize, PFNEGLINITIALIZEPROC);
    EGL_FUNCTION(eglChooseConfig, PFNEGLCHOOSECONFIGPROC);
    EGL_FUNCTION(eglCreatePbufferSurface, PFNEGLCREATEPBUFFERSURFACEPROC);
    EGL_FUNCTION(eglCreateContext, PFNEGLCREATECONTEXTPROC);
    EGL_FUNCTION(eglMakeCurrent, PFNEGLMAKECURRENTPROC);
    EGL_FUNCTION(eglDestroyContext, PFNEGLDESTROYCONTEXTPROC);
    EGL_FUNCTION(eglDestroySurface, PFNEGLDESTROYSURFACEPROC);
    EGL_FUNCTION(eglTerminate, PFNEGLTERMINATEPROC);
    EGL_FUNCTION(eglGetError, PFNEGLGETERRORPROC);
    auto platformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)getProc("eglGetPlatformDisplayEXT");
    if (!platformDisplay) return 3;
    EGLint attributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    EGLDisplay display = platformDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, attributes);
    EGLint major = 0, minor = 0;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
        fprintf(stderr, "Metal EGL initialization failed: 0x%x\n", eglGetError()); return 4;
    }
    EGLint configAttributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config; EGLint count = 0;
    if (!eglChooseConfig(display, configAttributes, &config, 1, &count) || count != 1) return 5;
    EGLint size[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, size);
    EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, version);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT || !eglMakeCurrent(display, surface, surface, context)) return 6;
    auto clearColor = (void (*)(GLfloat, GLfloat, GLfloat, GLfloat))getProc("glClearColor");
    auto clear = (void (*)(GLbitfield))getProc("glClear");
    auto read = (void (*)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))getProc("glReadPixels");
    auto string = (const GLubyte *(*)(GLenum))getProc("glGetString");
    if (!clearColor || !clear || !read || !string) return 7;
    clearColor(0.25, 0.5, 0.75, 1); clear(GL_COLOR_BUFFER_BIT);
    unsigned char pixel[4] = {}; read(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    const char *renderer = (const char *)string(GL_RENDERER);
    bool valid = abs(int(pixel[0]) - 64) <= 1 && abs(int(pixel[1]) - 128) <= 1 &&
                 abs(int(pixel[2]) - 191) <= 1 && pixel[3] == 255 && renderer && strstr(renderer, "Metal");
    printf("EGL %d.%d renderer=%s readback=%u,%u,%u,%u %s\n", major, minor, renderer ?: "nil", pixel[0], pixel[1], pixel[2], pixel[3], valid ? "PASS" : "FAIL");
    // iOS games ship PVRTC and only upload compressed textures when the extension is
    // advertised (GTA: LCS drew every surface with its 1x1 fallback texture without it).
    auto genTextures = (void (*)(GLsizei, GLuint *))getProc("glGenTextures");
    auto bindTexture = (void (*)(GLenum, GLuint))getProc("glBindTexture");
    auto compressed = (void (*)(GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLsizei, const void *))getProc("glCompressedTexImage2D");
    auto getError = (GLenum (*)())getProc("glGetError");
    if (!genTextures || !bindTexture || !compressed || !getError) return 7;
    const char *extensions = (const char *)string(GL_EXTENSIONS);
    bool pvrtcAdvertised = extensions && strstr(extensions, "GL_IMG_texture_compression_pvrtc");
    GLuint texture = 0; genTextures(1, &texture); bindTexture(GL_TEXTURE_2D, texture);
    static const unsigned char blocks[32] = {}; // 8x8 PVRTC 4bpp: four 8-byte blocks
    while (getError() != GL_NO_ERROR) {}
    compressed(GL_TEXTURE_2D, 0, 0x8C02 /* GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG */, 8, 8, 0, sizeof(blocks), blocks);
    GLenum pvrtcError = getError();
    bool pvrtc = pvrtcAdvertised && pvrtcError == GL_NO_ERROR;
    printf("PVRTC advertised=%d upload=0x%x %s\n", pvrtcAdvertised, pvrtcError, pvrtc ? "PASS" : "FAIL");
    valid = valid && pvrtc;
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context); eglDestroySurface(display, surface); eglTerminate(display);
    dlclose(library);
    return valid ? 0 : 8;
}
