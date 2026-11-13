// Pure geometry checks: no windows, cursor movement, or synthetic input.
#include "../runtime/include/PearTouchGeometry.h"
#include <cassert>
#include <cstdio>
static void near(CGPoint actual, CGFloat x, CGFloat y) {
    assert(fabs(actual.x - x) < 0.001 && fabs(actual.y - y) < 0.001);
}
int main() {
    // A portrait game fitted into a landscape Mac window: the displayed
    // centre and a point near the bottom must map into the game's own space.
    near(PearMapFittedTouch(CGPointMake(680, 499), CGSizeMake(768, 1024), CGSizeMake(768, 1024), CGSizeMake(1360, 998), true), 384, 512);
    near(PearMapFittedTouch(CGPointMake(680, 748.5), CGSizeMake(768, 1024), CGSizeMake(768, 1024), CGSizeMake(1360, 998), true), 384, 768);
    assert(CGSizeEqualToSize(PearOrientDrawableSize(CGSizeMake(320, 480), true, false), CGSizeMake(480, 320)));
    assert(CGSizeEqualToSize(PearOrientDrawableSize(CGSizeMake(480, 320), false, true), CGSizeMake(320, 480)));
    assert(CGSizeEqualToSize(PearOrientDrawableSize(CGSizeMake(320, 480), true, true), CGSizeMake(320, 480)));
    assert(CGSizeEqualToSize(PearOrientDrawableSize(CGSizeMake(320, 480), false, false), CGSizeMake(320, 480)));
    CGSize native = CGSizeMake(400, 800), reference = CGSizeMake(400, 800);
    near(PearMapFittedTouch(CGPointMake(300, 600), native, reference, CGSizeMake(800, 1600), true), 150, 300);
    near(PearMapFittedTouch(CGPointMake(450, 600), native, reference, CGSizeMake(1100, 1600), true), 150, 300);
    near(PearMapFittedTouch(CGPointMake(75, 150), native, reference, CGSizeMake(200, 400), true), 150, 300);
    near(PearMapFittedTouch(CGPointMake(450, 600), native, reference, CGSizeMake(1100, 1600), false), 450, 600);
    near(PearMapFittedTouch(CGPointMake(12, 34), CGSizeZero, reference, CGSizeMake(200, 400), true), 12, 34);
    near(PearMapFittedTouch(CGPointMake(40, 100), native, CGSizeMake(600, 800), CGSizeMake(800, 1600), true), 120, 50);
    CGRect fit = PearAspectFitRect(CGSizeMake(400, 800), CGRectMake(0, 0, 1100, 1600));
    assert(fabs(fit.origin.x - 150) < 0.001 && fabs(fit.origin.y) < 0.001);
    assert(fabs(fit.size.width - 800) < 0.001 && fabs(fit.size.height - 1600) < 0.001);
    assert(CGRectIsEmpty(PearAspectFitRect(CGSizeZero, CGRectMake(0, 0, 100, 100))));
    puts("PASS: legacy touch geometry across scales, margins and inactive fit");
}
