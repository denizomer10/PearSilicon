// Own synthetic app with imported system-GL ABI, not game automation.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>
#include <cassert>
#include <mach-o/dyld.h>
#import "../runtime/include/PearEAGLContext.h"
@interface EAGLContext : NSObject
- (instancetype)initWithAPI:(NSUInteger)api;
+ (BOOL)setCurrentContext:(EAGLContext *)context;
+ (EAGLContext *)currentContext;
- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id)drawable;
- (BOOL)presentRenderbuffer:(NSUInteger)target;
@end
extern "C" void *EAGLGetProcAddress(const char *);
int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 2) {
        assert(!strcmp(argv[1], "--native"));
        assert([NSStringFromClass(EAGLContext.class) isEqualToString:@"EAGLContext"]);
        assert(EAGLGetProcAddress("glClear") == nullptr);
        puts("PASS: opt-out preserves the system EAGL class and original proc import");
        return 0;
    }
    assert([NSStringFromClass(EAGLContext.class) isEqualToString:@"PearEAGLContext"]);
    assert(NSClassFromString(@"EAGLContext") == EAGLContext.class);
    assert(objc_getClass("EAGLContext") == EAGLContext.class);
    assert(objc_lookUpClass("EAGLContext") == EAGLContext.class);
    assert(objc_getMetaClass("EAGLContext") == object_getClass(EAGLContext.class));
    assert(NSClassFromString(@"NSString") == NSString.class);
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:2];
    assert(context && [EAGLContext setCurrentContext:context]);
    assert(EAGLContext.currentContext == context);
    GLuint rb = 0, fbo = 0;
    glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    CALayer *layer = [CALayer layer];
    layer.bounds = CGRectMake(0, 0, 16, 12); layer.contentsScale = 2;
    assert([context renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]);
    GLint width = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    assert(width == 32);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    glClearColor(0, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    unsigned char rgba[4] = {};
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    assert(rgba[0] == 0 && rgba[1] == 255 && rgba[2] == 0 && rgba[3] == 255);
#ifdef PEAR_EXCLUSIVE_PROBE
    void *handle = dlopen("@rpath/libPearOpenGLES.dylib", RTLD_NOW | RTLD_LOCAL);
#else
    void *handle = RTLD_DEFAULT;
#endif
    assert(handle);
#ifdef PEAR_EXCLUSIVE_PROBE
    void *legacyName = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_LOCAL);
    assert(legacyName); // Redirected to our ABI bridge, not the named OS path.
    assert(dlsym(legacyName, "glClear") == EAGLGetProcAddress("glClear"));
    dlclose(legacyName);
#endif
    void *dynamicClear = dlsym(handle, "glClear");
    assert(dynamicClear && dynamicClear == EAGLGetProcAddress("glClear"));
    assert(dlsym(RTLD_DEFAULT, "OBJC_CLASS_$_EAGLContext") == (__bridge void *)EAGLContext.class);
    assert(dlsym(RTLD_DEFAULT, "malloc"));
    assert(!dlsym(handle, "glPearNonexistentCommand"));
    auto dynamicColor = (void (*)(GLfloat, GLfloat, GLfloat, GLfloat))dlsym(handle, "glClearColor");
    dynamicColor(1, 1, 0, 1); ((void (*)(GLbitfield))dynamicClear)(GL_COLOR_BUFFER_BIT);
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    assert(rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 0 && glGetError() == GL_NO_ERROR);
    assert([context presentRenderbuffer:GL_RENDERBUFFER]);
    PearANGLEContext *core = [(id)context angleContext];
    PearANGLEDrawableGeometry geometry;
    assert([core copyDrawableGeometry:&geometry forRenderbuffer:rb]);
    glDeleteRenderbuffers(1, &rb);
    assert(![core copyDrawableGeometry:&geometry forRenderbuffer:rb]);
    assert([EAGLContext setCurrentContext:nil]);
#ifdef PEAR_EXCLUSIVE_PROBE
    for (uint32_t index = 0; index < _dyld_image_count(); ++index)
        assert(!strstr(_dyld_get_image_name(index), "/OpenGLES.framework/"));
    puts("PASS: exclusive GLES/EAGL bridge, no system OpenGLES image loaded");
#endif
    puts("PASS: Mach-O GL/class slots, dynamic proc/class lookup, Metal readback/presentation");
} }
