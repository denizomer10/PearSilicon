// Original EAGL-style allocation/presentation sequence, ANGLE GL objects only.
#import "../runtime/include/PearANGLEDrawable.h"
#import <QuartzCore/QuartzCore.h>
#include <GLES3/gl3.h>
#include <cassert>
#include <cmath>

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSError *error = nil;
        assert(PearANGLEInitialize([NSString stringWithUTF8String:argv[1]], &error));
#define PROC(type, var, symbol) auto var = (type)PearANGLEGetProcAddress(symbol); assert(var)
        PROC(PFNGLGENRENDERBUFFERSPROC, genRB, "glGenRenderbuffers");
        PROC(PFNGLBINDRENDERBUFFERPROC, bindRB, "glBindRenderbuffer");
        PROC(PFNGLGETRENDERBUFFERPARAMETERIVPROC, rbParameter, "glGetRenderbufferParameteriv");
        PROC(PFNGLRENDERBUFFERSTORAGEPROC, rbStorage, "glRenderbufferStorage");
        PROC(PFNGLGENFRAMEBUFFERSPROC, genFBO, "glGenFramebuffers");
        PROC(PFNGLBINDFRAMEBUFFERPROC, bindFBO, "glBindFramebuffer");
        PROC(PFNGLFRAMEBUFFERRENDERBUFFERPROC, attach, "glFramebufferRenderbuffer");
        PROC(PFNGLCLEARCOLORPROC, clearColor, "glClearColor");
        PROC(PFNGLCLEARPROC, clear, "glClear");
        PROC(PFNGLREADPIXELSPROC, read, "glReadPixels");
        PROC(PFNGLGETERRORPROC, glError, "glGetError");
        PROC(PFNGLGETINTEGERVPROC, get, "glGetIntegerv");
        PROC(PFNGLENABLEPROC, enable, "glEnable");
        PROC(PFNGLDISABLEPROC, disable, "glDisable");
        PROC(PFNGLISENABLEDPROC, enabled, "glIsEnabled");
        PROC(PFNGLVIEWPORTPROC, viewport, "glViewport");
        PROC(PFNGLDELETERENDERBUFFERSPROC, deleteRB, "glDeleteRenderbuffers");
#undef PROC
        for (NSNumber *version in @[@2, @3]) {
            PearANGLEContext *context = [[PearANGLEContext alloc] initWithClientVersion:version.integerValue sharegroup:nil error:&error];
            assert(context && [PearANGLEContext setCurrentContext:context error:&error]);
            CALayer *host = [CALayer layer];
            host.frame = CGRectMake(40, 60, 24, 16);
            host.bounds = CGRectMake(3, 5, 24, 16);
            host.contentsScale = 2;
            assert(![context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:host colorFormat:PearANGLEColorRGBA8 retainedBacking:NO error:&error]);
            GLuint rb = 0, fbo = 0;
            genRB(1, &rb); bindRB(GL_RENDERBUFFER, rb);
            assert(![context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:host colorFormat:PearANGLEColorRGB565 retainedBacking:NO error:&error]);
            assert(!context.hasWindowSurface);
            assert([context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:host colorFormat:PearANGLEColorRGBA8 retainedBacking:YES error:&error]);
            GLint width = 0, height = 0;
            rbParameter(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
            rbParameter(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
            assert(width == 48 && height == 32);
            PearANGLEDrawableGeometry geometry;
            assert([context copyDrawableGeometry:&geometry forRenderbuffer:rb]);
            assert(geometry.pixelSize.width == 48 && geometry.pixelSize.height == 32 && geometry.generation);
            uint64_t validGeneration = geometry.generation;
            assert(![context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:host colorFormat:PearANGLEColorSRGBA8 retainedBacking:NO error:&error]);
            assert([context copyDrawableGeometry:&geometry forRenderbuffer:rb] && geometry.generation == validGeneration);
            CGPoint pixel;
            assert([context mapLayerPoint:CGPointMake(15, 13) forRenderbuffer:rb generation:geometry.generation toPixel:&pixel]);
            assert(pixel.x == 24 && pixel.y == 16);
            dispatch_semaphore_t mapped = dispatch_semaphore_create(0);
            uint64_t inputGeneration = geometry.generation;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                assert(PearANGLEContext.currentContext == nil);
                PearANGLEDrawableGeometry snapshot;
                CGPoint inputPixel;
                assert([context copyDrawableGeometry:&snapshot forRenderbuffer:rb]);
                assert([context mapLayerPoint:CGPointMake(15, 13) forRenderbuffer:rb generation:inputGeneration toPixel:&inputPixel]);
                assert(inputPixel.x == 24 && inputPixel.y == 16);
                dispatch_semaphore_signal(mapped);
            });
            assert(dispatch_semaphore_wait(mapped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
            assert(![context mapLayerPoint:CGPointMake(0, 0) forRenderbuffer:rb generation:geometry.generation toPixel:&pixel]);
            assert(![context mapLayerPoint:CGPointMake(NAN, 13) forRenderbuffer:rb generation:geometry.generation toPixel:&pixel]);
            genFBO(1, &fbo); bindFBO(GL_FRAMEBUFFER, fbo);
            attach(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
            clearColor(0, 0, 1, 1); clear(GL_COLOR_BUFFER_BIT);
            viewport(1, 2, 3, 4); enable(GL_SCISSOR_TEST);
            GLuint otherReadFBO = 0;
            genFBO(1, &otherReadFBO);
            for (int frame = 0; frame < 4; ++frame) {
                if (version.integerValue == 3) bindFBO(GL_READ_FRAMEBUFFER, otherReadFBO);
                assert([context presentBoundRenderbuffer:GL_RENDERBUFFER error:&error]);
                GLint actualRead = 0, actualDraw = 0, actualRB = 0, actualViewport[4] = {};
                get(GL_READ_FRAMEBUFFER_BINDING, &actualRead);
                get(GL_DRAW_FRAMEBUFFER_BINDING, &actualDraw);
                get(GL_RENDERBUFFER_BINDING, &actualRB); get(GL_VIEWPORT, actualViewport);
                assert(actualRead == (version.integerValue == 3 ? otherReadFBO : fbo));
                assert(actualDraw == fbo && actualRB == rb && enabled(GL_SCISSOR_TEST));
                assert(actualViewport[0] == 1 && actualViewport[1] == 2 && actualViewport[2] == 3 && actualViewport[3] == 4);
                if (version.integerValue == 3) bindFBO(GL_READ_FRAMEBUFFER, fbo);
                unsigned char rgba[4] = {};
                read(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
                assert(rgba[0] == 0 && rgba[1] == 0 && rgba[2] == 255 && rgba[3] == 255);
                assert(glError() == GL_NO_ERROR);
            }
            // Presentation must not eat a caller's existing GL error.
            enable(0xdead);
            assert([context presentBoundRenderbuffer:GL_RENDERBUFFER error:&error]);
            assert(glError() == GL_INVALID_ENUM && glError() == GL_NO_ERROR);
            uint64_t oldGeneration = geometry.generation;
            host.bounds = CGRectMake(3, 5, 40, 24);
            assert(![context presentBoundRenderbuffer:GL_RENDERBUFFER error:&error]);
            assert(![context copyDrawableGeometry:&geometry forRenderbuffer:rb]);
            assert([context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:host colorFormat:PearANGLEColorRGBA8 retainedBacking:NO error:&error]);
            assert([context copyDrawableGeometry:&geometry forRenderbuffer:rb]);
            assert(geometry.generation > oldGeneration && geometry.pixelSize.width == 80 && geometry.pixelSize.height == 48);
            assert(![context mapLayerPoint:CGPointMake(23, 17) forRenderbuffer:rb generation:oldGeneration toPixel:&pixel]);
            assert([context mapLayerPoint:CGPointMake(23, 17) forRenderbuffer:rb generation:geometry.generation toPixel:&pixel]);
            assert(pixel.x == 40 && pixel.y == 24);
            disable(GL_SCISSOR_TEST); clearColor(1, 0, 0, 1); clear(GL_COLOR_BUFFER_BIT);
            assert([context presentBoundRenderbuffer:GL_RENDERBUFFER error:&error]);
            // A game can reallocate the same GL name directly: don't present it
            // using stale drawable dimensions.
            rbStorage(GL_RENDERBUFFER, GL_RGBA8, 8, 8);
            assert(![context presentBoundRenderbuffer:GL_RENDERBUFFER error:&error]);
            assert(![context copyDrawableGeometry:&geometry forRenderbuffer:rb]);
            assert([context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:nil colorFormat:PearANGLEColorRGBA8 retainedBacking:NO error:&error]);
            rbParameter(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
            assert(width == 0 && ![context copyDrawableGeometry:&geometry forRenderbuffer:rb]);
            assert(![context presentBoundRenderbuffer:GL_RENDERBUFFER error:&error]);
            assert(glError() == GL_NO_ERROR);
            deleteRB(1, &rb);
            assert([PearANGLEContext setCurrentContext:nil error:&error]);
            assert(![context allocateBoundRenderbuffer:GL_RENDERBUFFER fromLayer:host colorFormat:PearANGLEColorRGBA8 retainedBacking:NO error:&error]);
            printf("PASS: GLES %ld drawable allocation/presentation, retained pixels, GL state/error, resize generation and pixel mapping\n", (long)version.integerValue);
        }
    }
}
