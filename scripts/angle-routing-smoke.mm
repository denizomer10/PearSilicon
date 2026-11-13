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
#ifdef PEAR_EXCLUSIVE_PROBE
// iOS-only GL_APPLE_framebuffer_multisample, implemented on ANGLE by the runtime.
extern "C" void glRenderbufferStorageMultisampleAPPLE(GLenum, GLsizei, GLenum, GLsizei, GLsizei);
extern "C" void glResolveMultisampleFramebufferAPPLE(void);
@interface PearRGB565Layer : CALayer
@property(nonatomic, copy) NSDictionary *drawableProperties;
@end
@implementation PearRGB565Layer
@end
#endif
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
#ifdef PEAR_EXCLUSIVE_PROBE
    // Games see an iPhone's compression extensions: PVRTC, no desktop DXT/S3TC
    // (GTA III otherwise loads a DXT pack the iOS bundle does not ship).
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    assert(extensions && strstr(extensions, "GL_IMG_texture_compression_pvrtc"));
    assert(!strstr(extensions, "texture_compression_dxt") && !strstr(extensions, "texture_compression_s3tc"));
    // MSAA through the APPLE entry points: render blue, resolve into rb.
    GLuint msaaRB = 0, msaaFBO = 0;
    glGenRenderbuffers(1, &msaaRB); glBindRenderbuffer(GL_RENDERBUFFER, msaaRB);
    glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, 4, 0x8058 /* GL_RGBA8_OES */, 32, 24);
    glGenFramebuffers(1, &msaaFBO); glBindFramebuffer(GL_FRAMEBUFFER, msaaFBO);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, msaaRB);
    assert(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(0x8CA8 /* READ_FRAMEBUFFER_APPLE */, msaaFBO);
    glBindFramebuffer(0x8CA9 /* DRAW_FRAMEBUFFER_APPLE */, fbo);
    glResolveMultisampleFramebufferAPPLE();
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    assert(rgba[0] == 0 && rgba[1] == 0 && rgba[2] == 255 && glGetError() == GL_NO_ERROR);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    // RGB565 drawables (GTA III) get storage and an opaque layer.
    GLuint rgb565 = 0;
    glGenRenderbuffers(1, &rgb565); glBindRenderbuffer(GL_RENDERBUFFER, rgb565);
    PearRGB565Layer *layer565 = [PearRGB565Layer layer];
    layer565.bounds = CGRectMake(0, 0, 8, 8); layer565.contentsScale = 1;
    layer565.drawableProperties = @{@"EAGLDrawablePropertyColorFormat": @"EAGLColorFormat565"};
    // EAGL acts on the receiver even when no context is current (GTA III does
    // this from layout); the thread's current context is left as it was.
    assert([EAGLContext setCurrentContext:nil]);
    assert([context renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer565] && layer565.opaque);
    assert(EAGLContext.currentContext == nil);
    assert([EAGLContext setCurrentContext:context]);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    assert(width == 8);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    puts("PASS: iPhone extension profile, APPLE multisample resolve, RGB565 drawable");
#endif
    PearANGLEContext *core = [(id)context angleContext];
    PearANGLEDrawableGeometry geometry;
    assert([core copyDrawableGeometry:&geometry forRenderbuffer:rb]);
    glDeleteRenderbuffers(1, &rb);
    assert(![core copyDrawableGeometry:&geometry forRenderbuffer:rb]);
    assert([EAGLContext setCurrentContext:nil]);
    // GLES1 fixed-function clients use OES framebuffer entry points. The
    // native drawable bridge must allocate/present without issuing GLES2 calls.
    EAGLContext *legacy = [[EAGLContext alloc] initWithAPI:1];
    assert(legacy && [EAGLContext setCurrentContext:legacy]);
    auto genLegacyRB = (void (*)(GLsizei, GLuint *))EAGLGetProcAddress("glGenRenderbuffersOES");
    auto bindLegacyRB = (void (*)(GLenum, GLuint))EAGLGetProcAddress("glBindRenderbufferOES");
    auto genLegacyFB = (void (*)(GLsizei, GLuint *))EAGLGetProcAddress("glGenFramebuffersOES");
    auto bindLegacyFB = (void (*)(GLenum, GLuint))EAGLGetProcAddress("glBindFramebufferOES");
    auto attachLegacy = (void (*)(GLenum, GLenum, GLenum, GLuint))EAGLGetProcAddress("glFramebufferRenderbufferOES");
    GLuint legacyRB = 0, legacyFB = 0;
    // Unsuffixed ABI aliases are used by Dr. Driving even in its GLES1 context.
    glGenRenderbuffers(1, &legacyRB); glBindRenderbuffer(GL_RENDERBUFFER, legacyRB);
    assert(legacyRB && glGetError() == GL_NO_ERROR);
    CALayer *legacyLayer = [CALayer layer];
    legacyLayer.bounds = CGRectMake(0, 0, 16, 12); legacyLayer.contentsScale = 2;
    assert([legacy renderbufferStorage:GL_RENDERBUFFER fromDrawable:legacyLayer]);
    genLegacyFB(1, &legacyFB); bindLegacyFB(GL_FRAMEBUFFER, legacyFB);
    attachLegacy(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, legacyRB);
    glClearColor(0.2f, 0.4f, 0.8f, 1); glClear(GL_COLOR_BUFFER_BIT);
    assert(glGetError() == GL_NO_ERROR);
    assert([legacy presentRenderbuffer:GL_RENDERBUFFER]);
    assert(glGetError() == GL_NO_ERROR);
    auto deleteLegacyRB = (void (*)(GLsizei, const GLuint *))EAGLGetProcAddress("glDeleteRenderbuffersOES");
    deleteLegacyRB(1, &legacyRB);
    assert(glGetError() == GL_NO_ERROR);
    assert([EAGLContext setCurrentContext:nil]);
    puts("PASS: GLES1 OES drawable allocation and ANGLE/Metal presentation preserve GL error state");
#ifdef PEAR_EXCLUSIVE_PROBE
    for (uint32_t index = 0; index < _dyld_image_count(); ++index)
        assert(!strstr(_dyld_get_image_name(index), "/OpenGLES.framework/"));
    puts("PASS: exclusive GLES/EAGL bridge, no system OpenGLES image loaded");
#endif
    puts("PASS: Mach-O GL/class slots, dynamic proc/class lookup, Metal readback/presentation");
} }
