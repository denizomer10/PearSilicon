// In-memory window provider: no visible windows and no generated user input.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <cassert>
#include <unistd.h>
#import "../runtime/include/PearRuntime.h"
@interface PearScreenWindow : NSObject
@property(nonatomic) CGSize size;
@property(nonatomic) NSUInteger reads;
@end
@implementation PearScreenWindow
- (CGRect)bounds {
    assert(NSThread.isMainThread);
    self.reads++;
    return CGRectMake(0, 0, self.size.width, self.size.height);
}
@end
static PearScreenWindow *gTestWindow;
UIWindow *PearPrimaryWindow(void) { assert(NSThread.isMainThread); return (UIWindow *)(id)gTestWindow; }
void PearLog(NSString *format, ...) { (void)format; }
extern "C" int PearRuntimeModuleEnabled(const char *) { return 0; }
#import "../runtime/modules/graphics/ScreenShim.mm"
int main() { @autoreleasepool {
    gTestWindow = [PearScreenWindow new]; gTestWindow.size = CGSizeMake(800, 600);
    assert(CGSizeEqualToSize(PearReportedBounds().size, gTestWindow.size));
    NSUInteger initialReads = gTestWindow.reads;
    gTestWindow.size = CGSizeMake(1600, 900);
    usleep(70000);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int index = 0; index < 100; ++index)
            assert(CGSizeEqualToSize(PearReportedBounds().size, CGSizeMake(800, 600)));
        dispatch_semaphore_signal(finished);
    });
    assert(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    assert(gTestWindow.reads == initialReads && atomic_load(&gScreenRefreshQueued));
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (atomic_load(&gScreenRefreshQueued) && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    assert(!atomic_load(&gScreenRefreshQueued) && gTestWindow.reads == initialReads + 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        assert(CGSizeEqualToSize(PearReportedBounds().size, CGSizeMake(1600, 900)));
        dispatch_semaphore_signal(finished);
    });
    assert(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    PearSetScreenOverride(CGSizeMake(768, 1024));
    assert(CGSizeEqualToSize(PearReportedBounds().size, CGSizeMake(768, 1024)));
    PearClearScreenOverride();
    assert(CGSizeEqualToSize(PearReportedBounds().size, CGSizeMake(1600, 900)));
    puts("PASS: render-thread-only UIScreen reads refresh after resize, coalesced main-thread producer, fixed GL override isolation");
} }
