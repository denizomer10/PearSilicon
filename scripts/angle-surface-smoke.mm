// Own detached layers only: no desktop windows, activation or generated input.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "../runtime/include/PearANGLEContext.h"
#include <GLES3/gl3.h>
#include <cassert>

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSError *error = nil;
        assert(PearANGLEInitialize([NSString stringWithUTF8String:argv[1]], &error));
        PearANGLEContext *context = [[PearANGLEContext alloc] initWithClientVersion:3 sharegroup:nil error:&error];
        assert(context && [PearANGLEContext setCurrentContext:context error:&error]);
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.bounds = CGRectMake(0, 0, 20, 12);
        layer.contentsScale = 2;
        assert([context bindDrawableLayer:layer error:&error]);
        assert(context.hasWindowSurface && context.pixelWidth == 40 && context.pixelHeight == 24);
        assert([context bindDrawableLayer:layer error:&error]);
        assert(![context resizePixelWidth:16 height:16 error:&error] && error.code == 22);
        CALayer *empty = [CALayer layer];
        assert(![context bindDrawableLayer:empty error:&error]);
        assert(context.hasWindowSurface && context.pixelWidth == 40);
        auto clearColor = (void (*)(GLfloat, GLfloat, GLfloat, GLfloat))PearANGLEGetProcAddress("glClearColor");
        auto clear = (void (*)(GLbitfield))PearANGLEGetProcAddress("glClear");
        auto read = (void (*)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))PearANGLEGetProcAddress("glReadPixels");
        auto glError = (GLenum (*)(void))PearANGLEGetProcAddress("glGetError");
        assert(clearColor && clear && read && glError);
        clearColor(0, 1, 1, 1); clear(GL_COLOR_BUFFER_BIT);
        unsigned char pixel[4] = {};
        read(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        assert(pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 255 && pixel[3] == 255);
        assert(glError() == GL_NO_ERROR);
        assert([context presentFramebuffer:0 width:40 height:24 error:&error]);
        for (NSNumber *scale in @[@1, @2, @1.5]) {
            layer.bounds = CGRectMake(0, 0, 32, 16);
            layer.contentsScale = scale.doubleValue;
            assert(![context presentFramebuffer:0 width:40 height:24 error:&error] && error.code == 24);
            assert(![context bindDrawableLayer:layer error:&error] && error.code == 24);
            assert([context detachDrawableLayerWithError:&error]);
            assert(!context.hasWindowSurface);
            assert([context bindDrawableLayer:layer error:&error]);
            assert(context.pixelWidth == (NSUInteger)(32 * scale.doubleValue));
            assert(context.pixelHeight == (NSUInteger)(16 * scale.doubleValue));
            clearColor(0, 1, 1, 1); clear(GL_COLOR_BUFFER_BIT);
            read(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            assert(pixel[1] == 255 && pixel[2] == 255 && glError() == GL_NO_ERROR);
            assert([context presentFramebuffer:0 width:context.pixelWidth height:context.pixelHeight error:&error]);
        }
        assert([context detachDrawableLayerWithError:&error]);
        CALayer *host = [CALayer layer];
        host.frame = CGRectMake(100, 70, 28, 18);
        host.bounds = CGRectMake(5, 7, 28, 18);
        host.contentsScale = 2;
        assert([context bindDrawableLayer:host error:&error]);
        assert(host.sublayers.count == 1);
        CALayer *child = host.sublayers.firstObject;
        assert([child isKindOfClass:CAMetalLayer.class]);
        assert(CGRectEqualToRect(child.frame, host.bounds));
        assert(context.pixelWidth == 56 && context.pixelHeight == 36);
        clearColor(0, 1, 1, 1); clear(GL_COLOR_BUFFER_BIT);
        read(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        assert(pixel[1] == 255 && pixel[2] == 255 && glError() == GL_NO_ERROR);
        assert([context presentFramebuffer:0 width:56 height:36 error:&error]);
        // EGL must reject sharing one native host between two live surfaces.
        // The rejected transaction must leave the second context's pbuffer usable.
        PearANGLEContext *other = [[PearANGLEContext alloc] initWithClientVersion:3 sharegroup:nil error:&error];
        assert(other && [PearANGLEContext setCurrentContext:other error:&error]);
        assert(![other bindDrawableLayer:host error:&error]);
        assert(!other.hasWindowSurface && other.pixelWidth == 1 && other.pixelHeight == 1);
        clearColor(0, 1, 1, 1); clear(GL_COLOR_BUFFER_BIT);
        read(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        assert(pixel[1] == 255 && pixel[2] == 255 && glError() == GL_NO_ERROR);
        assert([PearANGLEContext setCurrentContext:context error:&error]);
        assert([context detachDrawableLayerWithError:&error]);
        assert(host.sublayers.count == 0);
        assert([context resizePixelWidth:8 height:8 error:&error]);
        assert([PearANGLEContext setCurrentContext:nil error:&error]);
        assert(![context bindDrawableLayer:layer error:&error] && error.code == 12);
        puts("ANGLE native-layer PASS: Metal readback/swap, scale rebind, host coordinates, stale geometry/duplicate host rejection, pbuffer recovery");
    }
}
