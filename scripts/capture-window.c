// capture-window.c
//
// Captures one window by CGWindowID without touching the active Space or
// bringing any application forward. Uses the window-list entry point at
// runtime because the SDK obsoleted it on macOS 15.
//
//   clang -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
//         -o /tmp/capture-window scripts/capture-window.c
//   /tmp/capture-window <window-id> <out.png>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef CGImageRef (*PearWindowImageFn)(CGRect, CGWindowListOption, CGWindowID,
                                        CGWindowImageOption);

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <window-id> <out.png>\n", argv[0]);
        return 2;
    }
    CGWindowID windowID = (CGWindowID)strtoul(argv[1], NULL, 10);
    PearWindowImageFn createImage =
        (PearWindowImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!createImage) {
        fprintf(stderr, "CGWindowListCreateImage unavailable\n");
        return 3;
    }

    CGImageRef image = createImage(CGRectNull, kCGWindowListOptionIncludingWindow,
                                   windowID,
                                   kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    if (!image) {
        fprintf(stderr, "could not capture window %u\n", (unsigned)windowID);
        return 4;
    }

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8 *)argv[2], (CFIndex)strlen(argv[2]), false);
    CGImageDestinationRef destination = NULL;
    if (url) {
        destination = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    }
    if (!destination) {
        fprintf(stderr, "could not create destination\n");
        CFRelease(image);
        if (url) CFRelease(url);
        return 5;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    bool ok = CGImageDestinationFinalize(destination);
    printf("%s %ux%u\n", ok ? "wrote" : "failed", (unsigned)CGImageGetWidth(image),
           (unsigned)CGImageGetHeight(image));
    CFRelease(destination);
    if (url) CFRelease(url);
    CFRelease(image);
    return ok ? 0 : 6;
}
