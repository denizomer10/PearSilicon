// A GLES client that does not link OpenGL ES and reaches it only at run time,
// as games that dlopen the framework do. The runtime arms routing from the
// bridge installed next to it; ANGLE must start on first use and the system
// OpenGLES image must never load.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <cstdio>
#include <cstring>

static bool SystemOpenGLESLoaded() {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "/OpenGLES.framework/")) return true;
    }
    return false;
}

int main() {
    @autoreleasepool {
        if (SystemOpenGLESLoaded()) { puts("FAIL: system OpenGLES loaded at launch"); return 1; }
        void *gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW);
        if (!gles) { puts("FAIL: OpenGLES dlopen was refused instead of routed"); return 1; }
        typedef const unsigned char *(*GetString)(unsigned int);
        GetString getString = (GetString)dlsym(gles, "glGetString");
        Dl_info info = {};
        if (!getString || !dladdr((void *)getString, &info) || !info.dli_fname) {
            puts("FAIL: glGetString was not resolved"); return 1;
        }
        Class context = NSClassFromString(@"EAGLContext");
        if (!context) { puts("FAIL: EAGLContext class missing"); return 1; }
        id instance = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)(context, @selector(alloc)), NSSelectorFromString(@"initWithAPI:"), 2);
        BOOL current = ((BOOL (*)(id, SEL, id))objc_msgSend)(context, NSSelectorFromString(@"setCurrentContext:"), instance);
        const char *renderer = current ? (const char *)getString(0x1F01 /* GL_RENDERER */) : nullptr;
        if (!renderer || !strstr(renderer, "ANGLE")) {
            printf("FAIL: renderer is %s\n", renderer ?: "(none)"); return 1;
        }
        if (SystemOpenGLESLoaded()) { puts("FAIL: system OpenGLES image was loaded"); return 1; }
        printf("PASS: run-time OpenGLES routed to %s, lazy ANGLE renderer \"%s\", no system OpenGLES image\n",
               strrchr(info.dli_fname, '/') + 1, renderer);
    }
    return 0;
}
