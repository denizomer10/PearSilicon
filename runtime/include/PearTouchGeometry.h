#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>

// A fixed-orientation GL app can create its first drawable with UIKit's stale
// opposite orientation. Keep its dimensions, but respect an unambiguous app
// declaration. Apps supporting both orientation families retain their size.
static inline CGSize PearOrientDrawableSize(CGSize size, bool landscape, bool portrait) {
    if (size.width <= 0 || size.height <= 0 || landscape == portrait) return size;
    if ((landscape && size.width < size.height) || (portrait && size.width > size.height))
        return CGSizeMake(size.height, size.width);
    return size;
}

// Center content in a container without cropping or changing its aspect ratio.
static inline CGRect PearAspectFitRect(CGSize content, CGRect container) {
    if (content.width <= 0 || content.height <= 0 ||
        container.size.width <= 0 || container.size.height <= 0) return CGRectZero;
    CGFloat scale = fmin(container.size.width / content.width, container.size.height / content.height);
    CGSize fitted = CGSizeMake(content.width * scale, content.height * scale);
    return CGRectMake(CGRectGetMidX(container) - fitted.width * 0.5,
                      CGRectGetMidY(container) - fitted.height * 0.5, fitted.width, fitted.height);
}

// Convert a point from the current aspect-fitted drawable to the window space
// in which the game's controls were laid out. No transform is valid until the
// rendering shim actually applies its fit.
static inline CGPoint PearMapFittedTouch(CGPoint point, CGSize native, CGSize reference,
                                         CGSize current, bool fitApplied) {
    if (!fitApplied || native.width < 1 || native.height < 1 ||
        reference.width < 1 || reference.height < 1 || current.width < 1 || current.height < 1) return point;
    CGFloat cs = fmin(current.width / native.width, current.height / native.height);
    CGFloat rs = fmin(reference.width / native.width, reference.height / native.height);
    if (cs <= 0 || rs <= 0) return point;
    CGPoint co = CGPointMake((current.width - native.width * cs) * 0.5,
                             (current.height - native.height * cs) * 0.5);
    CGPoint ro = CGPointMake((reference.width - native.width * rs) * 0.5,
                             (reference.height - native.height * rs) * 0.5);
    return CGPointMake(ro.x + (point.x - co.x) * rs / cs,
                       ro.y + (point.y - co.y) * rs / cs);
}
