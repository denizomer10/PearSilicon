#pragma once

// User intent survives focus changes. Losing focus suspends native capture;
// it does not act like Escape. Escape only releases, and a click re-arms, so a
// second Escape can never trap the cursor without a deliberate click.
struct PearPointerCaptureState {
    bool requested = true;
    bool suspended = false;
    bool escapeDown = false;

    bool wantsLock() const { return requested && !suspended; }
    void setActive(bool active) {
        suspended = !active;
        if (!active) escapeDown = false;
    }
    bool escape(bool pressed) {
        if (!pressed) { escapeDown = false; return false; }
        if (escapeDown) return false;
        escapeDown = true;
        if (!requested) return false;
        requested = false;
        return true;
    }
    void captureFromClick() { requested = true; }
};
