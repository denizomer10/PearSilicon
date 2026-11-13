#import "../runtime/include/PearEAGLContext.h"
#import <QuartzCore/QuartzCore.h>
#include <GLES2/gl2.h>
#include <cassert>
#include <pthread.h>

@interface PearTestDrawable : CALayer
@property(nonatomic, copy) NSDictionary *drawableProperties;
@end
@implementation PearTestDrawable
@end

static void *LeaveAdapterCurrent(void *value) {
    @autoreleasepool {
        PearEAGLContext *context = (__bridge_transfer PearEAGLContext *)value;
        assert([PearEAGLContext setCurrentContext:context]);
        assert(PearEAGLContext.currentContext == context);
    }
    return nullptr;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSError *error = nil;
        assert(PearANGLEInitialize([NSString stringWithUTF8String:argv[1]], &error));
        assert(![[PearEAGLContext alloc] initWithAPI:0]);
        PearEAGLContext *first = [[PearEAGLContext alloc] initWithAPI:2];
        assert(first && first.API == 2);
        PearEAGLContext *second = [[PearEAGLContext alloc] initWithAPI:2 sharegroup:first.sharegroup];
        assert(second && second.sharegroup == first.sharegroup);
        assert(![[PearEAGLContext alloc] initWithAPI:3 sharegroup:first.sharegroup]);
        assert([PearEAGLContext setCurrentContext:second]);
        assert(PearEAGLContext.currentContext == second && PearANGLEContext.currentContext == second.angleContext);
        second.debugLabel = @"Original ANGLE EAGL adapter test";
        second.multiThreaded = YES;
        assert(second.isMultiThreaded);
        auto gen = (void (*)(GLsizei, GLuint *))PearANGLEGetProcAddress("glGenRenderbuffers");
        auto bind = (void (*)(GLenum, GLuint))PearANGLEGetProcAddress("glBindRenderbuffer");
        auto genFBO = (void (*)(GLsizei, GLuint *))PearANGLEGetProcAddress("glGenFramebuffers");
        auto bindFBO = (void (*)(GLenum, GLuint))PearANGLEGetProcAddress("glBindFramebuffer");
        auto attach = (void (*)(GLenum, GLenum, GLenum, GLuint))PearANGLEGetProcAddress("glFramebufferRenderbuffer");
        auto clearColor = (void (*)(GLfloat, GLfloat, GLfloat, GLfloat))PearANGLEGetProcAddress("glClearColor");
        auto clear = (void (*)(GLbitfield))PearANGLEGetProcAddress("glClear");
        auto read = (void (*)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))PearANGLEGetProcAddress("glReadPixels");
        auto glError = (GLenum (*)(void))PearANGLEGetProcAddress("glGetError");
        assert(gen && bind && genFBO && bindFBO && attach && clearColor && clear && read && glError);
        GLuint rb = 0, fbo = 0;
        gen(1, &rb); bind(GL_RENDERBUFFER, rb);
        PearTestDrawable *drawable = [PearTestDrawable layer];
        drawable.bounds = CGRectMake(0, 0, 24, 16); drawable.contentsScale = 2;
        drawable.drawableProperties = @{@"EAGLDrawablePropertyColorFormat": @"EAGLColorFormat565"};
        assert(![second renderbufferStorage:GL_RENDERBUFFER fromDrawable:drawable] && second.lastError);
        drawable.drawableProperties = @{@"EAGLDrawablePropertyColorFormat": @"EAGLColorFormat8888", @"EAGLDrawablePropertyRetained": @YES};
        assert([second renderbufferStorage:GL_RENDERBUFFER fromDrawable:drawable] && !second.lastError);
        genFBO(1, &fbo); bindFBO(GL_FRAMEBUFFER, fbo);
        attach(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        clearColor(1, 0, 1, 1); clear(GL_COLOR_BUFFER_BIT);
        assert([second presentRenderbuffer:GL_RENDERBUFFER] && !second.lastError);
        unsigned char rgba[4] = {};
        read(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
        assert(rgba[0] == 255 && rgba[1] == 0 && rgba[2] == 255 && rgba[3] == 255 && glError() == GL_NO_ERROR);
        assert(![second presentRenderbuffer:GL_RENDERBUFFER atTime:1] && second.lastError.code == 5);
        assert(![second presentRenderbuffer:GL_RENDERBUFFER afterMinimumDuration:0.01]);
        assert([second presentRenderbuffer:GL_RENDERBUFFER] && !second.lastError);
        dispatch_semaphore_t checked = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            assert(![PearEAGLContext setCurrentContext:second]);
            assert(PearEAGLContext.currentContext == nil);
            dispatch_semaphore_signal(checked);
        });
        assert(dispatch_semaphore_wait(checked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        assert(PearEAGLContext.currentContext == second);
        assert([second renderbufferStorage:GL_RENDERBUFFER fromDrawable:nil]);
        assert(![second presentRenderbuffer:GL_RENDERBUFFER]);
        assert([PearEAGLContext setCurrentContext:nil]);
        assert(!PearEAGLContext.currentContext && !PearANGLEContext.currentContext);
        // Both wrapper and native context TLS must release their ownership on exit.
        for (int index = 0; index < 8; ++index) {
            PearEAGLContext *worker = [[PearEAGLContext alloc] initWithAPI:2 sharegroup:first.sharegroup];
            __weak PearEAGLContext *weakWorker = worker;
            pthread_t thread;
            assert(pthread_create(&thread, nullptr, LeaveAdapterCurrent, (__bridge_retained void *)worker) == 0);
            worker = nil;
            assert(pthread_join(thread, nullptr) == 0);
            assert(weakWorker == nil);
        }
        assert([PearEAGLContext setCurrentContext:first]);
        assert([PearEAGLContext setCurrentContext:nil]);
        puts("PASS: original EAGL selectors, sharegroups, drawable properties, RGBA8 presentation, ownership and 8 TLS release cycles");
    }
}
