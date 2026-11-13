// Original GLSL programs exercise ANGLE's real GLES -> Metal shader pipeline.
#import <Foundation/Foundation.h>
#import "../runtime/include/PearANGLEContext.h"
#include <GLES2/gl2.h>
#include <cassert>

template <typename T> static T Proc(const char *name) {
    T result = (T)PearANGLEGetProcAddress(name);
    assert(result);
    return result;
}

static void DrawTriangle(NSInteger version) {
    NSError *error = nil;
    PearANGLEContext *context = [[PearANGLEContext alloc] initWithClientVersion:version sharegroup:nil error:&error];
    assert(context && [context resizePixelWidth:64 height:64 error:&error]);
    assert([PearANGLEContext setCurrentContext:context error:&error]);
    auto createShader = Proc<GLuint (*)(GLenum)>("glCreateShader");
    auto shaderSource = Proc<void (*)(GLuint, GLsizei, const GLchar *const *, const GLint *)>("glShaderSource");
    auto compile = Proc<void (*)(GLuint)>("glCompileShader");
    auto shaderStatus = Proc<void (*)(GLuint, GLenum, GLint *)>("glGetShaderiv");
    auto shaderLog = Proc<void (*)(GLuint, GLsizei, GLsizei *, GLchar *)>("glGetShaderInfoLog");
    auto createProgram = Proc<GLuint (*)(void)>("glCreateProgram");
    auto attach = Proc<void (*)(GLuint, GLuint)>("glAttachShader");
    auto bindAttribute = Proc<void (*)(GLuint, GLuint, const GLchar *)>("glBindAttribLocation");
    auto link = Proc<void (*)(GLuint)>("glLinkProgram");
    auto programStatus = Proc<void (*)(GLuint, GLenum, GLint *)>("glGetProgramiv");
    auto programLog = Proc<void (*)(GLuint, GLsizei, GLsizei *, GLchar *)>("glGetProgramInfoLog");
    const char *vertex = version == 2
        ? "attribute vec2 p; void main(){gl_Position=vec4(p,0.0,1.0);}"
        : "#version 300 es\nin vec2 p; void main(){gl_Position=vec4(p,0.0,1.0);}";
    const char *fragment = version == 2
        ? "precision mediump float; void main(){gl_FragColor=vec4(1.0,1.0,0.0,1.0);}"
        : "#version 300 es\nprecision mediump float; out vec4 color; void main(){color=vec4(1.0,1.0,0.0,1.0);}";
    GLuint shaders[] = {createShader(GL_VERTEX_SHADER), createShader(GL_FRAGMENT_SHADER)};
    const char *sources[] = {vertex, fragment};
    for (int i = 0; i < 2; ++i) {
        shaderSource(shaders[i], 1, &sources[i], nullptr); compile(shaders[i]);
        GLint ready = 0; shaderStatus(shaders[i], GL_COMPILE_STATUS, &ready);
        if (!ready) { char log[1024] = {}; shaderLog(shaders[i], sizeof(log), nullptr, log); fprintf(stderr, "%s\n", log); }
        assert(ready);
    }
    GLuint program = createProgram();
    attach(program, shaders[0]); attach(program, shaders[1]); bindAttribute(program, 0, "p"); link(program);
    GLint ready = 0; programStatus(program, GL_LINK_STATUS, &ready);
    if (!ready) { char log[1024] = {}; programLog(program, sizeof(log), nullptr, log); fprintf(stderr, "%s\n", log); }
    assert(ready);
    auto gen = Proc<void (*)(GLsizei, GLuint *)>("glGenBuffers");
    auto bind = Proc<void (*)(GLenum, GLuint)>("glBindBuffer");
    auto bufferData = Proc<void (*)(GLenum, GLsizeiptr, const void *, GLenum)>("glBufferData");
    auto attribute = Proc<void (*)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *)>("glVertexAttribPointer");
    auto enableAttribute = Proc<void (*)(GLuint)>("glEnableVertexAttribArray");
    auto use = Proc<void (*)(GLuint)>("glUseProgram");
    auto viewport = Proc<void (*)(GLint, GLint, GLsizei, GLsizei)>("glViewport");
    auto draw = Proc<void (*)(GLenum, GLint, GLsizei)>("glDrawArrays");
    auto read = Proc<void (*)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *)>("glReadPixels");
    auto glError = Proc<GLenum (*)(void)>("glGetError");
    GLuint buffer = 0; gen(1, &buffer); bind(GL_ARRAY_BUFFER, buffer);
    const GLfloat triangle[] = {-1, -1, 3, -1, -1, 3};
    bufferData(GL_ARRAY_BUFFER, sizeof(triangle), triangle, GL_STATIC_DRAW);
    attribute(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr); enableAttribute(0);
    use(program); viewport(0, 0, 64, 64); draw(GL_TRIANGLES, 0, 3);
    unsigned char pixel[4] = {}; read(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    assert(pixel[0] == 255 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255);
    assert(glError() == GL_NO_ERROR);
    Proc<void (*)(GLsizei, const GLuint *)>("glDeleteBuffers")(1, &buffer);
    Proc<void (*)(GLuint)>("glDeleteProgram")(program);
    Proc<void (*)(GLuint)>("glDeleteShader")(shaders[0]);
    Proc<void (*)(GLuint)>("glDeleteShader")(shaders[1]);
    assert([PearANGLEContext setCurrentContext:nil error:&error]);
    printf("PASS: GLES %ld GLSL compile/link/Metal triangle readback=255,255,0,255\n", (long)version);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSError *error = nil;
        assert(PearANGLEInitialize([NSString stringWithUTF8String:argv[1]], &error));
        DrawTriangle(2); DrawTriangle(3);
    }
}
