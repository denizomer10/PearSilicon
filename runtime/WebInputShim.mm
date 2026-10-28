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
  var FALLBACK_CLASS = 'pear-date-fallback';

  function normalize(value) {
    var digits = (value || '').replace(/[^0-9]/g, '').slice(0, 6);
    return digits.length > 4 ? digits.slice(0, 4) + '-' + digits.slice(4) : digits;
  }

  function enableButton() {
    var button = document.getElementById('age_gate_button') ||
                 document.querySelector('[id*="age" i][id*="button" i]');
    if (!button) return;
    button.style.pointerEvents = 'auto';
    button.classList.remove('no-display');
    button.removeAttribute('disabled');
  }

  function setValue(field, value) {
    field.value = value;
    field.dispatchEvent(new Event('input', {bubbles: true}));
    field.dispatchEvent(new Event('change', {bubbles: true}));
    enableButton();
  }

  // The consent page hides its confirm button until its wheel picker fires.
  // With a mouse the picker's touch-only BScroll never scrolls, so give the
  // user a plain text field that writes the same YYYY-MM value the form reads.
  function makeFallback(field) {
    if (field.__pearFallback) return;
    var input = document.createElement('input');
    input.type = 'text';
    input.className = FALLBACK_CLASS;
    input.setAttribute('inputmode', 'numeric');
    input.setAttribute('placeholder', 'YYYY-MM');
    input.setAttribute('autocomplete', 'bday');
    input.style.cssText =
      'display:block;margin:8px auto 0;padding:8px 10px;' +
      'font:16px -apple-system,Roboto,Arial,sans-serif;text-align:center;' +
      'border:1px solid #c8c8c8;border-radius:8px;width:12ch;color:#111;' +
      'background:#fff;pointer-events:auto;user-select:text;-webkit-user-select:text;';
    input.addEventListener('input', function () {
      var value = normalize(input.value);
      input.value = value;
      setValue(field, value);
    });
    input.addEventListener('focus', enableButton);
    field.__pearFallback = input;
    if (field.parentNode) field.parentNode.insertBefore(input, field.nextSibling);
  }

  // The page's date picker registers a touchstart/touchend pair whenever
  // `'ontouchstart' in window` is true. WKWebView on macOS exposes the property
  // but mouse clicks do not produce touch events, so the picker never opens.
  function syntheticTap(element) {
    try {
      var rect = element.getBoundingClientRect();
      var x = rect.left + rect.width / 2;
      var y = rect.top + rect.height / 2;
      var touch = new Touch({identifier: 1, target: element, clientX: x, clientY: y,
                             pageX: x, pageY: y, screenX: x, screenY: y});
      ['touchstart', 'touchend'].forEach(function (type) {
        element.dispatchEvent(new TouchEvent(type, {
          bubbles: true, cancelable: true,
          touches: type === 'touchend' ? [] : [touch],
          targetTouches: type === 'touchend' ? [] : [touch],
          changedTouches: [touch]
        }));
      });
    } catch (error) {
      // TouchEvent is unavailable; the field remains typeable.
    }
  }

  function enable(field) {
    if (field.__pearDateInput) {
      makeFallback(field);
      return;
    }
    field.__pearDateInput = true;

    field.removeAttribute('readonly');
    field.readOnly = false;
    field.style.pointerEvents = 'auto';
    field.style.webkitUserSelect = 'text';
    field.style.userSelect = 'text';
    field.setAttribute('inputmode', 'numeric');
    field.setAttribute('autocomplete', 'bday');
    if (!field.getAttribute('placeholder') || field.getAttribute('placeholder') === '-') {
      field.setAttribute('placeholder', 'YYYY-MM');
    }

    // Do not stop propagation: the page's picker listens on this element.
    field.addEventListener('click', function () {
      enableButton();
      setTimeout(function () {
        if (!document.querySelector('.datepicker-panel, .datepicker-container')) {
          syntheticTap(field);
        }
      }, 50);
    }, true);

    field.addEventListener('input', function () {
      var value = normalize(field.value);
      if (value !== field.value) field.value = value;
      enableButton();
    });
    field.addEventListener('change', enableButton);
    field.addEventListener('focus', enableButton);

    makeFallback(field);
  }

  function scan() {
    var nodes = document.querySelectorAll(
      'input#date_of_birth,' +
      'input[id*="birth" i],' +
      'input[name*="birth" i],' +
      'input[class*="birth" i],' +
      'input[readonly][id*="date" i],' +
      'input[readonly][name*="date" i]'
    );
    for (var i = 0; i < nodes.length; i++) enable(nodes[i]);
  }

  function start() {
    scan();
    if (document.documentElement) {
      new MutationObserver(scan).observe(document.documentElement, {
        childList: true, subtree: true
      });
    }
    setTimeout(scan, 500);
    setTimeout(scan, 1500);
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
    if (method) {
        IMP original = method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^id(id self, CGRect frame, id configuration) {
            PearInstallDateInputScript(configuration);
            return ((id (*)(id, SEL, CGRect, id))original)(self, selector, frame, configuration);
        }));
    }

    // Storyboard/NIB-created web views do not pass through the frame/configuration
    // initializer. Install the same script on the configuration they build while
    // decoding; it applies to the first navigation afterwards.
    SEL coderSelector = @selector(initWithCoder:);
    Method coder = class_getInstanceMethod(webViewClass, coderSelector);
    if (coder) {
        IMP original = method_getImplementation(coder);
        method_setImplementation(coder, imp_implementationWithBlock(^id(id self, NSCoder *decoder) {
            id webView = ((id (*)(id, SEL, NSCoder *))original)(self, coderSelector, decoder);
            id configuration = ((id (*)(id, SEL))objc_msgSend)(webView, @selector(configuration));
            PearInstallDateInputScript(configuration);
            return webView;
        }));
    }
}

__attribute__((constructor))
static void PearWebInputShimInit(void) {
    @autoreleasepool {
        PearInstallWebInputShim();
    }
}
