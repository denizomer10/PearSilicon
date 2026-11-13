// Real ANGLE contexts, no visible windows and no generated user input.
#import <Foundation/Foundation.h>
#import "../runtime/include/PearANGLEContext.h"
#include <GLES2/gl2.h>
#include <cassert>
#include <pthread.h>

static void *LeaveContextCurrent(void *value) {
    @autoreleasepool {
        PearANGLEContext *context = (__bridge_transfer PearANGLEContext *)value;
        assert([PearANGLEContext setCurrentContext:context error:nullptr]);
        // Intentionally leave current: pthread TLS cleanup owns the unbind.
    }
    return nullptr;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSError *error = nil;
        assert(PearANGLEInitialize([NSString stringWithUTF8String:argv[1]], &error));
        assert(![[PearANGLEContext alloc] initWithClientVersion:0 sharegroup:nil error:&error]);
        PearANGLEContext *first = [[PearANGLEContext alloc] initWithClientVersion:2 sharegroup:nil error:&error];
        assert(first && first.pixelWidth == 1 && first.pixelHeight == 1);
        assert([PearANGLEContext setCurrentContext:first error:&error]);
        auto gen = (void (*)(GLsizei, GLuint *))PearANGLEGetProcAddress("glGenTextures");
        auto bind = (void (*)(GLenum, GLuint))PearANGLEGetProcAddress("glBindTexture");
        auto texture = (GLboolean (*)(GLuint))PearANGLEGetProcAddress("glIsTexture");
        auto clearColor = (void (*)(GLfloat, GLfloat, GLfloat, GLfloat))PearANGLEGetProcAddress("glClearColor");
        auto clear = (void (*)(GLbitfield))PearANGLEGetProcAddress("glClear");
        auto read = (void (*)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))PearANGLEGetProcAddress("glReadPixels");
        assert(gen && bind && texture && clearColor && clear && read);
        GLuint shared = 0; gen(1, &shared); bind(GL_TEXTURE_2D, shared);
        PearANGLESharegroup *group = first.sharegroup;
        PearANGLEContext *second = [[PearANGLEContext alloc] initWithClientVersion:2 sharegroup:group error:&error];
        assert(second && second.sharegroup == group);
        assert(![[PearANGLEContext alloc] initWithClientVersion:3 sharegroup:group error:&error]);
        assert([PearANGLEContext currentContext] == first);
        assert([PearANGLEContext setCurrentContext:second error:&error]);
        assert(texture(shared));
        for (NSNumber *size in @[@16, @64, @8, @32]) {
            assert([second resizePixelWidth:size.unsignedIntegerValue height:24 error:&error]);
            assert(second.pixelWidth == size.unsignedIntegerValue && second.pixelHeight == 24);
            clearColor(1, 0, 0, 1); clear(GL_COLOR_BUFFER_BIT);
            unsigned char pixel[4] = {}; read(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            assert(pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255);
        }
        assert(![second resizePixelWidth:0 height:24 error:&error]);
        assert(second.pixelWidth == 32 && [PearANGLEContext currentContext] == second);
        auto genFBO = (void (*)(GLsizei, GLuint *))PearANGLEGetProcAddress("glGenFramebuffers");
        auto bindFBO = (void (*)(GLenum, GLuint))PearANGLEGetProcAddress("glBindFramebuffer");
        auto image = (void (*)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *))PearANGLEGetProcAddress("glTexImage2D");
        auto attach = (void (*)(GLenum, GLenum, GLenum, GLuint, GLint))PearANGLEGetProcAddress("glFramebufferTexture2D");
        auto viewport = (void (*)(GLint, GLint, GLsizei, GLsizei))PearANGLEGetProcAddress("glViewport");
        auto enable = (void (*)(GLenum))PearANGLEGetProcAddress("glEnable");
        auto disable = (void (*)(GLenum))PearANGLEGetProcAddress("glDisable");
        auto scissor = (void (*)(GLint, GLint, GLsizei, GLsizei))PearANGLEGetProcAddress("glScissor");
        auto colorMask = (void (*)(GLboolean, GLboolean, GLboolean, GLboolean))PearANGLEGetProcAddress("glColorMask");
        auto get = (void (*)(GLenum, GLint *))PearANGLEGetProcAddress("glGetIntegerv");
        auto isEnabled = (GLboolean (*)(GLenum))PearANGLEGetProcAddress("glIsEnabled");
        assert(genFBO && bindFBO && image && attach && viewport && enable && disable && scissor && colorMask && get && isEnabled);
        GLuint source = 0, sourceTexture = 0;
        genFBO(1, &source); gen(1, &sourceTexture); bind(GL_TEXTURE_2D, sourceTexture);
        image(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        bindFBO(GL_FRAMEBUFFER, source);
        attach(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sourceTexture, 0);
        clearColor(0, 0, 1, 1); clear(GL_COLOR_BUFFER_BIT);
        viewport(1, 2, 3, 4); enable(GL_SCISSOR_TEST); scissor(0, 0, 1, 1);
        colorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        assert(![second presentFramebuffer:source width:16 height:16 error:&error]);
        assert([second resizePixelWidth:16 height:16 error:&error]);
        assert([second presentFramebuffer:source width:16 height:16 error:&error]);
        GLint actualFBO = 0, actualViewport[4] = {}, actualMask[4] = {};
        get(GL_FRAMEBUFFER_BINDING, &actualFBO); get(GL_VIEWPORT, actualViewport); get(GL_COLOR_WRITEMASK, actualMask);
        assert((GLuint)actualFBO == source && isEnabled(GL_SCISSOR_TEST));
        assert(actualViewport[0] == 1 && actualViewport[1] == 2 && actualViewport[2] == 3 && actualViewport[3] == 4);
        assert(!actualMask[0] && !actualMask[1] && !actualMask[2] && !actualMask[3]);
        GLuint incomplete = 0; genFBO(1, &incomplete);
        assert(![second presentFramebuffer:incomplete width:16 height:16 error:&error]);
        get(GL_FRAMEBUFFER_BINDING, &actualFBO);
        assert((GLuint)actualFBO == source && isEnabled(GL_SCISSOR_TEST));
        bindFBO(GL_FRAMEBUFFER, 0);
        unsigned char presented[4] = {}; read(15, 15, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presented);
        auto glError = (GLenum (*)(void))PearANGLEGetProcAddress("glGetError");
        printf("presentation readback=%u,%u,%u,%u error=0x%x\n", presented[0], presented[1], presented[2], presented[3], glError());
        fflush(stdout);
        assert(presented[0] == 0 && presented[1] == 0 && presented[2] == 255 && presented[3] == 255);
        enable(0xDEAD); // Preserve an error owned by the caller, do not drain it.
        assert([second presentFramebuffer:source width:16 height:16 error:&error]);
        assert(glError() == GL_INVALID_ENUM && glError() == GL_NO_ERROR);
        disable(GL_SCISSOR_TEST); colorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        // The wrong thread must not steal or resize a current context.
        dispatch_semaphore_t checked = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                NSError *threadError = nil;
                assert([PearANGLEContext currentContext] == nil);
                assert(![PearANGLEContext setCurrentContext:second error:&threadError]);
                assert(![second resizePixelWidth:2 height:2 error:&threadError]);
                dispatch_semaphore_signal(checked);
            }
        });
        assert(dispatch_semaphore_wait(checked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        assert([PearANGLEContext setCurrentContext:nil error:&error]);
        first = nil; // Sharing must survive destruction of the first context.
        PearANGLEContext *third = [[PearANGLEContext alloc] initWithClientVersion:2 sharegroup:group error:&error];
        assert(third && [PearANGLEContext setCurrentContext:third error:&error] && texture(shared));
        assert([PearANGLEContext setCurrentContext:nil error:&error]);
        for (int cycle = 0; cycle < 16; ++cycle) {
            pthread_t dedicated;
            assert(pthread_create(&dedicated, nullptr, LeaveContextCurrent, (__bridge_retained void *)third) == 0);
            assert(pthread_join(dedicated, nullptr) == 0); // Includes TLS destructors.
            BOOL rebound = [PearANGLEContext setCurrentContext:third error:&error];
            if (!rebound) fprintf(stderr, "thread-exit rebind error: %s\n", error.localizedDescription.UTF8String);
            assert(rebound);
            assert([PearANGLEContext setCurrentContext:nil error:&error]);
        }
        // Migration to another thread is valid after explicit unbind.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                assert([PearANGLEContext setCurrentContext:second error:nullptr]);
                assert([second resizePixelWidth:12 height:12 error:nullptr]);
                assert([PearANGLEContext setCurrentContext:nil error:nullptr]);
                dispatch_semaphore_signal(checked);
            }
        });
        assert(dispatch_semaphore_wait(checked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        assert([PearANGLEContext currentContext] == nil);
        PearANGLEContext *es3 = [[PearANGLEContext alloc] initWithClientVersion:3 sharegroup:nil error:&error];
        assert(es3 && [es3 resizePixelWidth:32 height:24 error:&error]);
        assert([PearANGLEContext setCurrentContext:es3 error:&error]);
        genFBO(1, &source); gen(1, &sourceTexture); bind(GL_TEXTURE_2D, sourceTexture);
        image(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        bindFBO(GL_FRAMEBUFFER, source);
        attach(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sourceTexture, 0);
        clearColor(0, 1, 0, 1); clear(GL_COLOR_BUFFER_BIT);
        assert([es3 presentFramebuffer:source width:16 height:16 error:&error]);
        bindFBO(GL_FRAMEBUFFER, 0);
        read(31, 23, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presented);
        assert(presented[0] == 0 && presented[1] == 255 && presented[2] == 0 && presented[3] == 255);
        assert(glError() == GL_NO_ERROR);
        assert([PearANGLEContext setCurrentContext:nil error:&error]);
        puts("PASS: ANGLE sharing, resize, GLES2/3 presentation/state, rollback and 16 thread-exit cycles");
    }
}
