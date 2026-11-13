#import <Foundation/Foundation.h>
#import "../runtime/include/PearANGLEBackend.h"
#include <cassert>
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        assert(PearANGLEDisplay() == EGL_NO_DISPLAY);
        assert(PearANGLEGetProcAddress("glClear") == nullptr);
        NSError *error = nil;
        assert(!PearANGLEInitialize(@"relative", &error) && error);
        error = nil;
        assert(!PearANGLEInitialize(@"/tmp/pear-angle-missing-library", &error) && error);
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        assert(PearANGLEInitialize(directory, &error));
        assert(PearANGLEDisplay() != EGL_NO_DISPLAY);
        assert(PearANGLEGetProcAddress("glClear") != nullptr);
        assert(PearANGLEInitialize(directory, nullptr));
        assert(!PearANGLEInitialize(@"/tmp/another-angle-backend", &error));
        puts("PASS: Catalyst ANGLE loader, failure recovery and immutable backend selection");
    }
}
