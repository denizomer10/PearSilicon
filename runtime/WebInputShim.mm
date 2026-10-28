// WebInputShim.mm
//
// Makes date-of-birth fields in an app's web consent form usable with a
// keyboard. Web age gates commonly use a read-only <input> plus a custom wheel
// picker written in JavaScript. On a Mac the picker's touch handling does not
// open, leaving the user with a field they cannot fill in.
//
// The shim injects a small user script into every WKWebView. For birth-date
// inputs it removes `readonly`, accepts typed digits and normalises them to
// the YYYY-MM value the page expects
// `date_of_birth` as `new Date("YYYY-MM")`). It does not choose a date and does
// not submit the form; the user still has to type their own date and press the
// page's button.
//
// Opt out with PEAR_NO_WEB_INPUT_SHIM=1.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "PearRuntime.h"

static const char *kPearDateInputScript = R"JS(
(function () {
  function enableBirthDateInputs() {
    var nodes = document.querySelectorAll(
      'input#date_of_birth,' +
      'input[id*="birth" i],' +
      'input[name*="birth" i],' +
      'input[class*="birth" i],' +
      'input[readonly][id*="date" i],' +
      'input[readonly][name*="date" i]'
    );
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.__pearDateInput) continue;
      el.__pearDateInput = true;

      el.removeAttribute('readonly');
      el.readOnly = false;
      el.style.pointerEvents = 'auto';
      el.style.webkitUserSelect = 'text';
      el.style.userSelect = 'text';
      el.setAttribute('inputmode', 'numeric');
      el.setAttribute('autocomplete', 'bday');
      if (!el.getAttribute('placeholder') || el.getAttribute('placeholder') === '-') {
        el.setAttribute('placeholder', 'YYYY-MM');
      }

      // The page's custom wheel picker listens for touch/click on this field.
      // Let the field take focus for typing without opening the hidden panel.
      ['click', 'mousedown', 'touchstart'].forEach(function (type) {
        el.addEventListener(type, function (event) {
          event.stopImmediatePropagation();
        }, true);
      });

      el.addEventListener('focus', function () {
        var button = document.getElementById('age_gate_button');
        if (button) {
          button.style.pointerEvents = 'auto';
          button.classList.remove('no-display');
        }
      });

      el.addEventListener('input', function () {
        var digits = el.value.replace(/[^0-9]/g, '').slice(0, 6);
        el.value = digits.length > 4
          ? digits.slice(0, 4) + '-' + digits.slice(4)
          : digits;
        var button = document.getElementById('age_gate_button');
        if (button) {
          button.style.pointerEvents = 'auto';
          button.classList.remove('no-display');
        }
      });
    }
  }

  function start() {
    enableBirthDateInputs();
    var observer = new MutationObserver(enableBirthDateInputs);
    observer.observe(document.documentElement || document, {
      childList: true,
      subtree: true
    });
    setTimeout(enableBirthDateInputs, 500);
    setTimeout(enableBirthDateInputs, 1500);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
)JS";

static char kPearWebInputConfigurationKey;

static BOOL PearWebInputShimDisabled(void) {
    const char *value = getenv("PEAR_NO_WEB_INPUT_SHIM");
    return value && value[0] && strcmp(value, "0") != 0;
}

static void PearInstallDateInputScript(id configuration) {
    if (!configuration) return;
    if (objc_getAssociatedObject(configuration, &kPearWebInputConfigurationKey)) return;
    objc_setAssociatedObject(configuration, &kPearWebInputConfigurationKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id controller = ((id (*)(id, SEL))objc_msgSend)(
        configuration, @selector(userContentController));
    if (!controller) {
        Class controllerClass = NSClassFromString(@"WKUserContentController");
        if (!controllerClass) return;
        controller = ((id (*)(id, SEL))objc_msgSend)((id)controllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(
            configuration, @selector(setUserContentController:), controller);
    }

    Class scriptClass = NSClassFromString(@"WKUserScript");
    if (!scriptClass || !controller) return;

    NSString *source = [NSString stringWithUTF8String:kPearDateInputScript];
    id script = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, @selector(alloc));
    // WKUserScriptInjectionTimeAtDocumentEnd == 1
    script = ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
        script, @selector(initWithSource:injectionTime:forMainFrameOnly:),
        source, (NSInteger)1, (BOOL)NO);
    if (!script) return;

    ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(addUserScript:), script);
    PearLog(@"[PearRuntime][web] date input shim installed");
}

static void PearInstallWebInputShim(void) {
    if (PearWebInputShimDisabled()) return;
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (!webViewClass) return;

    SEL selector = @selector(initWithFrame:configuration:);
    Method method = class_getInstanceMethod(webViewClass, selector);
    if (!method) return;

    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^id(id self, CGRect frame, id configuration) {
        PearInstallDateInputScript(configuration);
        return ((id (*)(id, SEL, CGRect, id))original)(self, selector, frame, configuration);
    }));
}

__attribute__((constructor))
static void PearWebInputShimInit(void) {
    @autoreleasepool {
        PearInstallWebInputShim();
    }
}
