// This file also compiles as plain C/C++. Keep early sysctl access independent
// of the Objective-C runtime and of libPearRuntime's host client.
#include "PearDeviceProfile.h"
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t gProfileOnce = PTHREAD_ONCE_INIT;
static PearDeviceProfile gProfile;
static char gValues[5][PEAR_DEVICE_PROFILE_LEGACY_MAX_BYTES + 1];
static char gBundle[PEAR_DEVICE_PROFILE_BUNDLE_MAX_BYTES + 1];
static char gVendor[37];
static const char *const kKeys[6] = {
    "PEAR_DEVICE_MODEL", "PEAR_DEVICE_NAME", "PEAR_FAKE_IOS_VERSION",
    "PEAR_FAKE_IOS_BUILD", "PEAR_FAKE_DARWIN", "PEAR_DEVICE_IDIOM"
};
static const char *const kDefaults[5] = {
    "iPhone15,2", "iPhone", "16.0", "20A000", "22.6.0"
};

static int PearReject(PearDeviceProfileStatus status, const char *key) {
    gProfile.status = status;
    gProfile.invalidField = key;
    return 0;
}

static int PearCopy(char *destination, const char *text, size_t maximum, const char *key) {
    if (!text) return PearReject(PearDeviceProfileStatusMissingField, key);
    size_t length = strnlen(text, maximum + 1);
    if (length > maximum) return PearReject(PearDeviceProfileStatusTooLong, key);
    memcpy(destination, text, length + 1);
    return 1;
}

static int PearAlpha(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static int PearDigit(unsigned char c) {
    return c >= '0' && c <= '9';
}

static int PearModel(const char *text) {
    if (!PearAlpha((unsigned char)text[0])) return 0;
    for (size_t i = 1; text[i]; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (!PearAlpha(c) && !PearDigit(c) && c != ',' && c != '_' && c != '-') return 0;
    }
    return 1;
}

static int PearVersion(const char *text) {
    unsigned parts = 1, digits = 0;
    for (size_t i = 0; text[i]; ++i) {
        if (PearDigit((unsigned char)text[i])) {
            if (++digits > 4) return 0;
        } else if (text[i] == '.' && digits && ++parts <= 3) {
            digits = 0;
        } else {
            return 0;
        }
    }
    return digits != 0;
}

static int PearBuild(const char *text) {
    if (!PearAlpha((unsigned char)text[0]) && !PearDigit((unsigned char)text[0])) return 0;
    for (size_t i = 1; text[i]; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (!PearAlpha(c) && !PearDigit(c) && c != '.' && c != '_' && c != '-') return 0;
    }
    return 1;
}

static int PearUnicodeControl(uint32_t c) {
    // Unicode Cc/Cf (including bidi/format controls), without Foundation/ICU.
    return c <= 0x1F || (c >= 0x7F && c <= 0x9F) || c == 0xAD
        || (c >= 0x600 && c <= 0x605) || c == 0x61C || c == 0x6DD || c == 0x70F
        || (c >= 0x890 && c <= 0x891) || c == 0x8E2 || c == 0x180E
        || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E)
        || (c >= 0x2060 && c <= 0x2064) || (c >= 0x2066 && c <= 0x206F)
        || c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB) || c == 0x110BD || c == 0x110CD
        || (c >= 0x13430 && c <= 0x1343F) || (c >= 0x1BCA0 && c <= 0x1BCA3)
        || (c >= 0x1D173 && c <= 0x1D17A) || c == 0xE0001 || (c >= 0xE0020 && c <= 0xE007F);
}

static int PearUTF8Text(const char *text) {
    const unsigned char *p = (const unsigned char *)text;
    while (*p) {
        uint32_t c = *p++;
        unsigned extra = 0;
        uint32_t minimum = 0;
        if (c >= 0xC2 && c <= 0xDF) { c &= 0x1F; extra = 1; minimum = 0x80; }
        else if (c >= 0xE0 && c <= 0xEF) { c &= 0x0F; extra = 2; minimum = 0x800; }
        else if (c >= 0xF0 && c <= 0xF4) { c &= 0x07; extra = 3; minimum = 0x10000; }
        else if (c >= 0x80) return 0;
        while (extra--) {
            if (*p < 0x80 || *p > 0xBF) return 0;
            c = (c << 6) | (*p++ & 0x3F);
        }
        if (c < minimum || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)
            || PearUnicodeControl(c)) return 0;
    }
    return 1;
}

static int PearEqualASCII(const char *text, const char *lower) {
    if (!text) return 0;
    for (; *lower; ++lower, ++text) {
        unsigned char c = (unsigned char)*text;
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (c != (unsigned char)*lower) return 0;
    }
    return *text == 0;
}

static const char *PearIdiom(const char *text, int managed) {
    if (PearEqualASCII(text, "pad") || PearEqualASCII(text, "ipad")) return "pad";
    if (!managed || PearEqualASCII(text, "phone") || PearEqualASCII(text, "iphone")) return "phone";
    return NULL;
}

static int PearUUID(char *text) {
    if (strlen(text) != 36) return 0;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (text[i] != '-') return 0;
        } else {
            unsigned char c = (unsigned char)text[i];
            if (c >= 'a' && c <= 'f') c -= 'a' - 'A';
            if (!PearDigit(c) && !(c >= 'A' && c <= 'F')) return 0;
            text[i] = (char)c;
        }
    }
    return 1;
}

static void PearCaptureProfile(void) {
    const char *source = getenv("PEAR_DEVICE_PROFILE_SOURCE");
    const char *bundle = getenv("PEAR_DEVICE_PROFILE_BUNDLE");
    const char *vendor = getenv("PEAR_DEVICE_VENDOR_UUID");
    int managed = source != NULL || bundle != NULL || vendor != NULL;
    gProfile.source = managed ? PearDeviceProfileSourceUnknown : PearDeviceProfileSourceLegacy;
    if (managed) {
        // Exact marker also fixes the schema. Never fall back to legacy when
        // somebody supplies a future, empty, or incomplete managed snapshot.
        if (!source || strcmp(source, "host-v1")) {
            PearReject(PearDeviceProfileStatusInvalidSource, "PEAR_DEVICE_PROFILE_SOURCE");
            return;
        }
        gProfile.source = PearDeviceProfileSourceHostV1;
        if (!PearCopy(gBundle, bundle, sizeof(gBundle) - 1, "PEAR_DEVICE_PROFILE_BUNDLE")
            || !PearCopy(gVendor, vendor, sizeof(gVendor) - 1, "PEAR_DEVICE_VENDOR_UUID")) return;
        if (!gBundle[0] || !PearUTF8Text(gBundle)) {
            PearReject(PearDeviceProfileStatusInvalidField, "PEAR_DEVICE_PROFILE_BUNDLE");
            return;
        }
        if (!PearUUID(gVendor)) {
            PearReject(PearDeviceProfileStatusInvalidField, "PEAR_DEVICE_VENDOR_UUID");
            return;
        }
    }

    static const size_t managedLimits[5] = { 63, 127, 14, 64, 14 };
    for (size_t i = 0; i < 5; ++i) {
        const char *text = getenv(kKeys[i]);
        if (!managed && (!text || !text[0])) text = kDefaults[i];
        if (!PearCopy(gValues[i], text, managed ? managedLimits[i] : PEAR_DEVICE_PROFILE_LEGACY_MAX_BYTES,
                      kKeys[i])) return;
        if (managed) {
            int valid = i == 0 ? PearModel(gValues[i]) : i == 1 ? gValues[i][0] && PearUTF8Text(gValues[i])
                : i == 3 ? PearBuild(gValues[i]) : PearVersion(gValues[i]);
            if (!valid) {
                PearReject(PearDeviceProfileStatusInvalidField, kKeys[i]);
                return;
            }
        }
    }
    const char *idiomText = getenv(kKeys[5]);
    const char *idiom = PearIdiom(idiomText, managed);
    if (!idiom) {
        PearReject(idiomText ? PearDeviceProfileStatusInvalidField : PearDeviceProfileStatusMissingField, kKeys[5]);
        return;
    }

    // Publish values only after the ENTIRE snapshot has passed. pthread_once
    // provides publication to concurrent readers; nothing here can reenter a
    // sysctl hook (no allocation, logging, ObjC, IPC, or initializer callbacks).
    gProfile.bundle = managed ? gBundle : NULL;
    gProfile.model = gValues[0];
    gProfile.name = gValues[1];
    gProfile.idiom = idiom;
    gProfile.systemName = "iOS";
    gProfile.systemVersion = gValues[2];
    gProfile.systemBuild = gValues[3];
    gProfile.darwinRelease = gValues[4];
    gProfile.vendorIdentifier = managed ? gVendor : NULL;
    gProfile.status = PearDeviceProfileStatusReady;
}

const PearDeviceProfile *PearDeviceProfileGet(void) {
    pthread_once(&gProfileOnce, PearCaptureProfile);
    return &gProfile;
}
