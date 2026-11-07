#include "../runtime/include/PearPointerCaptureState.h"
#include <cassert>
#include <cstdio>

int main() {
    PearPointerCaptureState state;
    assert(state.wantsLock());
    state.setActive(false);
    assert(!state.wantsLock() && state.requested);
    state.setActive(true);
    assert(state.wantsLock()); // Command-Tab round trip restores intent.
    assert(state.escape(true) && !state.wantsLock());
    assert(!state.escape(true) && !state.wantsLock()); // No double release.
    assert(!state.escape(false));
    state.setActive(false);
    state.setActive(true);
    assert(!state.wantsLock()); // Explicit Escape remains respected.
    assert(!state.escape(true)); // Escape while released does not re-arm.
    state.captureFromClick();
    assert(state.wantsLock());
    state.setActive(false);
    assert(!state.wantsLock());
    state.setActive(true);
    assert(state.escape(true) && !state.wantsLock());
    puts("PASS: capture focus recovery, Escape release and click reacquisition");
}
