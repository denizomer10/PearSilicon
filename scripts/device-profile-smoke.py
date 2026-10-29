#!/usr/bin/env python3
"""Headless device-profile tests; production sources, temporary files, no UIKit/HTTP.

Usage: python3 scripts/device-profile-smoke.py [path/to/.build/debug/PearSilicon]
The optional CLI is invoked ONLY as host-service, with private temp HOME/data,
socket, token, and six device inputs. No game, app installation, GUI, or device.set.
Without the CLI, deterministic authenticated peers test the startup handoff.
Requires macOS/CLT and Python's standard library. Does not build the Swift CLI.
"""

import argparse

import json
import os
from pathlib import Path
import plistlib
import re
import select
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unicodedata
import uuid

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "device-profile-smoke-token"
BUNDLE = "com.pearsilicon.device-profile-smoke"
MAX_FRAME = 1_048_576
INPUTS = {
    "model": "PEAR_DEVICE_MODEL", "name": "PEAR_DEVICE_NAME", "idiom": "PEAR_DEVICE_IDIOM",
    "systemVersion": "PEAR_FAKE_IOS_VERSION", "systemBuild": "PEAR_FAKE_IOS_BUILD",
    "darwinRelease": "PEAR_FAKE_DARWIN",
}
DEFAULTS = dict(model="iPhone15,2", name="iPhone", idiom="phone", systemVersion="16.0",
                systemBuild="20A000", darwinRelease="22.6.0")
OVERRIDES = dict(model="iPad14,3", name="Pear 平板 🍐", idiom="pad", systemVersion="18.2.1",
                 systemBuild="22C_123-a", darwinRelease="24.2.0")
VALUE_FIELDS = ("bundle", "model", "name", "idiom", "systemName", "systemVersion", "systemBuild",
                "darwinRelease", "vendorIdentifier")
WIRE_FIELDS = set(VALUE_FIELDS) | {"schema"}

# Shared test code is C, including an optional constructor read before main.
# Race FIRST access, then mutate environ only AFTER capture while readers run.
# TEST_DEVICE additionally exercises the actual production sysctl value helpers;
# interposition and all shim constructors stay disabled for the entire child.
SUPPORT = r'''
#include "PearDeviceProfile.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void CheckProfile(const PearDeviceProfile *p) {
    assert(p);
    const char *fields[] = {p->model, p->name, p->idiom, p->systemName,
        p->systemVersion, p->systemBuild, p->darwinRelease};
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i)
        assert((fields[i] != NULL) == (p->status == PearDeviceProfileStatusReady));
    if (p->status != PearDeviceProfileStatusReady) assert(!p->bundle && !p->vendorIdentifier);
#ifdef TEST_DEVICE
    PearDeviceValue value;
    int available = PearDeviceValueForName("hw.machine", &value);
    assert(available == (p->status == PearDeviceProfileStatusReady));
    if (available) {
        assert(value.text == p->model);
        size_t length = 0;
        assert(PearWriteDeviceValue(&value, NULL, &length) == 0);
        assert(length == strlen(p->model) + 1);
        char text[PEAR_DEVICE_PROFILE_LEGACY_MAX_BYTES + 1];
        size_t small = 0;
        assert(PearWriteDeviceValue(&value, text, &small) == -1 && errno == ENOMEM);
        assert(small == length);
        assert(PearWriteDeviceValue(&value, text, &length) == 0);
        assert(!strcmp(text, p->model));
    }
    assert(PearDeviceValueForName("hw.memsize", &value));
    assert(value.number == 6ULL * 1024 * 1024 * 1024 && value.size == 8);
    assert(PearDeviceValueForName("hw.ncpu", &value) && value.number == 6 && value.size == 4);
    const char *kernel[] = {"kern.osproductversion", "kern.osversion", "kern.osrelease"};
    const char *texts[] = {p->systemVersion, p->systemBuild, p->darwinRelease};
    for (unsigned i = 0; i < 3; ++i) {
        available = PearDeviceValueForName(kernel[i], &value);
        assert(available == (p->status == PearDeviceProfileStatusReady && getenv("PEAR_DEVICE_KERNEL") != NULL));
        if (available) assert(value.text == texts[i]);
    }
#endif
}

static uint64_t Fingerprint(const PearDeviceProfile *p) {
    uint64_t hash = (uint64_t)p->source * 31 + (uint64_t)p->status;
    const char *fields[] = {p->invalidField, p->bundle, p->model, p->name, p->idiom,
        p->systemName, p->systemVersion, p->systemBuild, p->darwinRelease, p->vendorIdentifier};
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) {
        for (const unsigned char *s = (const unsigned char *)fields[i]; s && *s; ++s)
            hash = (hash ^ *s) * 1099511628211ULL;
        hash *= 1099511628211ULL;
    }
    return hash;
}

#define WORKERS 12
static pthread_mutex_t gGate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gCondition = PTHREAD_COND_INITIALIZER;
static unsigned gReady;
static int gGo;
static void *ReadWorker(void *unused) {
    pthread_mutex_lock(&gGate);
    ++gReady;
    pthread_cond_broadcast(&gCondition);
    while (!gGo) pthread_cond_wait(&gCondition, &gGate);
    pthread_mutex_unlock(&gGate);
    const PearDeviceProfile *first = PearDeviceProfileGet();
    uint64_t fingerprint = Fingerprint(first);
    for (unsigned i = 0; i < 1000; ++i) {
        const PearDeviceProfile *p = PearDeviceProfileGet();
        assert(p == first && fingerprint == Fingerprint(p));
        CheckProfile(p);
    }
    return (void *)first;
}
static void StartReaders(pthread_t *threads) {
    gReady = 0;
    gGo = 0;
    for (unsigned i = 0; i < WORKERS; ++i) assert(!pthread_create(&threads[i], NULL, ReadWorker, NULL));
    pthread_mutex_lock(&gGate);
    while (gReady != WORKERS) pthread_cond_wait(&gCondition, &gGate);
    gGo = 1;
    pthread_cond_broadcast(&gCondition);
    pthread_mutex_unlock(&gGate);
}
static void JoinReaders(pthread_t *threads) {
    const PearDeviceProfile *p = PearDeviceProfileGet();
    for (unsigned i = 0; i < WORKERS; ++i) {
        void *result = NULL;
        assert(!pthread_join(threads[i], &result));
        assert(result == p);
    }
}
static void ConcurrentCapture(void) {
    pthread_t threads[WORKERS];
    StartReaders(threads);
    JoinReaders(threads);
}
static void Mutate(void) {
    const PearDeviceProfile *p = PearDeviceProfileGet();
    uint64_t fingerprint = Fingerprint(p);
    pthread_t threads[WORKERS];
    StartReaders(threads);
    const char *keys[] = {"PEAR_DEVICE_MODEL", "PEAR_DEVICE_NAME", "PEAR_DEVICE_IDIOM",
        "PEAR_FAKE_IOS_VERSION", "PEAR_FAKE_IOS_BUILD", "PEAR_FAKE_DARWIN",
        "PEAR_DEVICE_PROFILE_SOURCE", "PEAR_DEVICE_PROFILE_BUNDLE", "PEAR_DEVICE_VENDOR_UUID"};
    for (unsigned n = 0; n < 100; ++n) {
        for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
            assert(!setenv(keys[i], "changed-invalid-value", 1));
            assert(!unsetenv(keys[i]));
        }
    }
    JoinReaders(threads);
    assert(p == PearDeviceProfileGet() && fingerprint == Fingerprint(p));
}
__attribute__((constructor)) static void EarlyCapture(void) {
    if (getenv("PEAR_PROFILE_TEST_EARLY")) CheckProfile(PearDeviceProfileGet());
}

#ifndef TEST_DEVICE
static void Quote(const char *text) {
    if (!text) { fputs("null", stdout); return; }
    putchar('"');
    for (const unsigned char *s = (const unsigned char *)text; *s; ++s) {
        if (*s == '"' || *s == '\\') printf("\\%c", *s);
        else if (*s < 0x20) printf("\\u%04x", *s);
        else putchar(*s);
    }
    putchar('"');
}
static void Emit(void) {
    const PearDeviceProfile *p = PearDeviceProfileGet();
    printf("{\"source\":%d,\"status\":%d", (int)p->source, (int)p->status);
    const char *keys[] = {"invalidField", "bundle", "model", "name", "idiom", "systemName",
        "systemVersion", "systemBuild", "darwinRelease", "vendorIdentifier"};
    const char *values[] = {p->invalidField, p->bundle, p->model, p->name, p->idiom, p->systemName,
        p->systemVersion, p->systemBuild, p->darwinRelease, p->vendorIdentifier};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        printf(",\"%s\":", keys[i]); Quote(values[i]);
    }
    puts("}");
    fflush(stdout);
}
int main(void) {
    ConcurrentCapture();
    Emit();
    char command[32];
    while (fgets(command, sizeof(command), stdin)) {
        if (!strcmp(command, "quit\n")) return 0;
        if (!strcmp(command, "mutate\n")) Mutate();
        else assert(!strcmp(command, "read\n"));
        Emit();
    }
    return 0;
}
#endif
'''

SHIM_IMPORTS = r'''
#import "PearRuntime.h"
#import "DeviceShim.mm"
// Only disambiguate TU-local helpers; compile the full production shims intact.
#define PearDeviceModel PearNetworkModelForTest
#define PearIOSVersion PearNetworkVersionForTest
#import "NetworkShim.mm"
#undef PearDeviceModel
#undef PearIOSVersion
void PearLog(NSString *format, ...) {}
#define TEST_DEVICE 1
#include "support.h"
'''

SHIMS = SHIM_IMPORTS + r'''
static id Text(const char *text) { return text ? [NSString stringWithUTF8String:text] : NSNull.null; }
static NSDictionary *Profile(void) {
    const PearDeviceProfile *p = PearDeviceProfileGet();
    return @{ @"source": @(p->source), @"status": @(p->status), @"invalidField": Text(p->invalidField),
        @"bundle": Text(p->bundle), @"model": Text(p->model), @"name": Text(p->name),
        @"idiom": Text(p->idiom), @"systemName": Text(p->systemName), @"systemVersion": Text(p->systemVersion),
        @"systemBuild": Text(p->systemBuild), @"darwinRelease": Text(p->darwinRelease),
        @"vendorIdentifier": Text(p->vendorIdentifier) };
}
static void Emit(void) {
    @autoreleasepool {
        assert(getenv("PEAR_NO_DEVICE_SHIM") && getenv("PEAR_NO_NETWORK_SHIM"));
        assert(!gInstalled && !gMockAccelerometer && !gMockGyro);
        assert(!NSClassFromString(@"UIDevice") && !NSClassFromString(@"UIApplication"));
        NSDictionary *supplied = @{ @"User-Agent": @"App-Supplied-UA", @"X-Device-Model": @"app-model",
            @"X-OS-Version": @"app-version", @"Other": @"preserved" };
        gKeepUA = YES;
        NSDictionary *kept = PearMergedHeaders(supplied);
        NSDictionary *macKept = PearMergedHeaders(@{ @"User-Agent": @"Macintosh; Mac OS X" });
        gKeepUA = NO;
        NSDictionary *replaced = PearMergedHeaders(supplied);
        NSUUID *vendor = PearSyntheticVendorID();
        NSDictionary *result = @{ @"profile": Profile(), @"constructorsDisabled": @YES,
            @"device": @{ @"modelIdentifier": PearDeviceModel() ?: NSNull.null,
                @"name": PearDeviceName() ?: NSNull.null, @"systemVersion": PearIOSVersion() ?: NSNull.null,
                @"systemBuild": PearIOSBuild() ?: NSNull.null, @"darwinRelease": PearDarwinRelease() ?: NSNull.null,
                @"pad": @(PearWantsPadIdiom()), @"vendorIdentifier": vendor.UUIDString ?: NSNull.null },
            @"vendorSeedBundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
            @"headers": PearMergedHeaders(@{}), @"kept": kept, @"replaced": replaced, @"macKept": macKept };
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        assert(data);
        fwrite(data.bytes, 1, data.length, stdout);
        putchar('\n');
        fflush(stdout);
    }
}
int main(void) {
    // Pure C production sysctl helpers, on racing workers before any ObjC test calls.
    assert(getenv("PEAR_NO_DEVICE_SHIM") && getenv("PEAR_NO_NETWORK_SHIM"));
    ConcurrentCapture();
    Emit();
    char command[32];
    while (fgets(command, sizeof(command), stdin)) {
        if (!strcmp(command, "quit\n")) return 0;
        if (!strcmp(command, "mutate\n")) Mutate();
        else assert(!strcmp(command, "read\n"));
        Emit();
    }
    return 0;
}
'''


# Recompile the verbatim installer bodies against prefixed NSObject fixtures.
# Only the COPIED device installer gets a test opt-out predicate/class lookup;
# the actual constructors/interposers keep PEAR_NO_*_SHIM=1 throughout. Network
# factory names are redirected only inside its copy, never in the real helpers.
# This exercises installer-level gates without adding production test seams or
# ever patching UIKit, real Foundation networking classes, or interposition.
INSTALLERS = SHIM_IMPORTS + r'''
@interface PearProfileDeviceFixture : NSObject
- (NSString *)model;
- (NSString *)localizedModel;
- (NSString *)systemName;
- (NSString *)systemVersion;
- (NSString *)name;
- (NSUUID *)identifierForVendor;
- (NSInteger)userInterfaceIdiom;
- (float)batteryLevel;
- (NSInteger)batteryState;
- (BOOL)isBatteryMonitoringEnabled;
- (BOOL)isMultitaskingSupported;
@end
@implementation PearProfileDeviceFixture
- (NSString *)model { return @"native-model"; }
- (NSString *)localizedModel { return @"native-localized-model"; }
- (NSString *)systemName { return @"native-system"; }
- (NSString *)systemVersion { return @"native-version"; }
- (NSString *)name { return @"native-name"; }
- (NSUUID *)identifierForVendor {
    return [[NSUUID alloc] initWithUUIDString:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"];
}
- (NSInteger)userInterfaceIdiom { return 5; }
- (float)batteryLevel { return -1.0f; }
- (NSInteger)batteryState { return 0; }
- (BOOL)isBatteryMonitoringEnabled { return NO; }
- (BOOL)isMultitaskingSupported { return NO; }
@end
@interface PearProfileTraitsFixture : NSObject
- (NSInteger)userInterfaceIdiom;
@end
@implementation PearProfileTraitsFixture
- (NSInteger)userInterfaceIdiom { return 5; }
@end

static Class gFixtureDevice, gFixtureTraits;
static BOOL gFixtureDeviceDisabled;
static BOOL PearFixtureDeviceDisabled(void) { return gFixtureDeviceDisabled; }
static Class PearFixtureClassFromString(NSString *name) {
    if ([name isEqualToString:@"UIDevice"]) return gFixtureDevice;
    assert([name isEqualToString:@"UITraitCollection"]);
    return gFixtureTraits;
}
#define PearInstallDeviceProperties PearFixtureInstallDeviceProperties
#define PearDeviceShimDisabled PearFixtureDeviceDisabled
#define NSClassFromString PearFixtureClassFromString
#include "device-installer.inc"
#undef NSClassFromString
#undef PearDeviceShimDisabled
#undef PearInstallDeviceProperties

static unsigned gFixtureRequests, gFixtureConfigurations, gFixtureSessions, gFixtureH3Setters;
@interface PearProfileRequestFixture : NSObject
+ (instancetype)requestWithURL:(NSURL *)url;
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
- (void)setAllHTTPHeaderFields:(NSDictionary *)headers;
@end
@implementation PearProfileRequestFixture
+ (instancetype)requestWithURL:(NSURL *)url { ++gFixtureRequests; return [self new]; }
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {}
- (void)setAllHTTPHeaderFields:(NSDictionary *)headers {}
@end
@interface PearProfileConfigurationFixture : NSObject
+ (instancetype)defaultSessionConfiguration;
+ (instancetype)ephemeralSessionConfiguration;
- (NSDictionary *)HTTPAdditionalHeaders;
- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers;
- (BOOL)assumesHTTP3Capable;
- (void)setAssumesHTTP3Capable:(BOOL)value;
@end
@implementation PearProfileConfigurationFixture
+ (instancetype)defaultSessionConfiguration { ++gFixtureConfigurations; return [self new]; }
+ (instancetype)ephemeralSessionConfiguration { ++gFixtureConfigurations; return [self new]; }
- (NSDictionary *)HTTPAdditionalHeaders { return @{ @"Other": @"native-header" }; }
- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {}
- (BOOL)assumesHTTP3Capable { return YES; }
- (void)setAssumesHTTP3Capable:(BOOL)value { ++gFixtureH3Setters; }
@end
@interface PearProfileSessionFixture : NSObject
+ (instancetype)sharedSession;
- (id)dataTaskWithRequest:(id)request;
- (id)dataTaskWithRequest:(id)request completionHandler:(void *)handler;
- (id)downloadTaskWithRequest:(id)request;
- (id)downloadTaskWithRequest:(id)request completionHandler:(void *)handler;
- (id)uploadTaskWithRequest:(id)request fromData:(NSData *)data;
- (id)uploadTaskWithRequest:(id)request fromFile:(NSURL *)file;
@end
@implementation PearProfileSessionFixture
+ (instancetype)sharedSession { ++gFixtureSessions; return [self new]; }
- (id)dataTaskWithRequest:(id)request { return nil; }
- (id)dataTaskWithRequest:(id)request completionHandler:(void *)handler { return nil; }
- (id)downloadTaskWithRequest:(id)request { return nil; }
- (id)downloadTaskWithRequest:(id)request completionHandler:(void *)handler { return nil; }
- (id)uploadTaskWithRequest:(id)request fromData:(NSData *)data { return nil; }
- (id)uploadTaskWithRequest:(id)request fromFile:(NSURL *)file { return nil; }
@end
#define PearInstallNetworkShim PearFixtureInstallNetworkShim
#define NSMutableURLRequest PearProfileRequestFixture
#define NSURLSessionConfiguration PearProfileConfigurationFixture
#define NSURLSession PearProfileSessionFixture
#include "network-installer.inc"
#undef NSURLSession
#undef NSURLSessionConfiguration
#undef NSMutableURLRequest
#undef PearInstallNetworkShim

static IMP Implementation(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    assert(method);
    return method_getImplementation(method);
}
static Class FreshDeviceClass(Class fixture) {
    static unsigned serial;
    char name[64];
    snprintf(name, sizeof(name), "PearProfileSmokeClass%u", ++serial);
    Class cls = objc_allocateClassPair(NSObject.class, name, 0);
    assert(cls);
    unsigned count = 0;
    Method *methods = class_copyMethodList(fixture, &count);
    for (unsigned i = 0; i < count; ++i)
        assert(class_addMethod(cls, method_getName(methods[i]), method_getImplementation(methods[i]),
                               method_getTypeEncoding(methods[i])));
    free(methods);
    objc_registerClassPair(cls);
    return cls;
}
static void Flag(const char *key, BOOL present) {
    // Empty values still count as present under the existing opt-out semantics.
    assert(present ? !setenv(key, "", 1) : !unsetenv(key));
}
static void ExpectPatch(Class cls, Class fixture, SEL selector, BOOL patched) {
    assert((Implementation(cls, selector) != Implementation(fixture, selector)) == patched);
}
static void DeviceCase(BOOL disabled, BOOL noUI, BOOL details, BOOL forceTraits) {
    assert(PearDeviceShimDisabled()); // The REAL interposers are never enabled.
    gFixtureDevice = FreshDeviceClass(PearProfileDeviceFixture.class);
    gFixtureTraits = FreshDeviceClass(PearProfileTraitsFixture.class);
    gFixtureDeviceDisabled = disabled;
    Flag("PEAR_NO_DEVICE_UI", noUI);
    Flag("PEAR_DEVICE_UI_DETAILS", details);
    Flag("PEAR_FORCE_TRAIT_IDIOM", forceTraits);
    PearFixtureInstallDeviceProperties();
    BOOL enabled = !disabled && !noUI;
    BOOL ready = PearDeviceProfileGet()->status == PearDeviceProfileStatusReady;
    SEL identity[] = { @selector(model), @selector(localizedModel), @selector(systemName),
        @selector(systemVersion), @selector(name) };
    for (SEL selector : identity)
        ExpectPatch(gFixtureDevice, PearProfileDeviceFixture.class, selector, enabled && ready);
    SEL battery[] = { @selector(batteryLevel), @selector(batteryState), @selector(isBatteryMonitoringEnabled) };
    for (SEL selector : battery)
        ExpectPatch(gFixtureDevice, PearProfileDeviceFixture.class, selector, enabled);
    ExpectPatch(gFixtureDevice, PearProfileDeviceFixture.class, @selector(identifierForVendor), enabled && details && ready);
    ExpectPatch(gFixtureDevice, PearProfileDeviceFixture.class, @selector(userInterfaceIdiom), enabled && details && ready);
    ExpectPatch(gFixtureDevice, PearProfileDeviceFixture.class, @selector(isMultitaskingSupported), enabled && details);
    ExpectPatch(gFixtureTraits, PearProfileTraitsFixture.class, @selector(userInterfaceIdiom), enabled && forceTraits && ready);
    PearProfileDeviceFixture *device = [[gFixtureDevice alloc] init];
    PearProfileTraitsFixture *traits = [[gFixtureTraits alloc] init];
    assert(device.batteryLevel == (enabled ? 0.87f : -1.0f));
    assert(device.batteryState == (enabled ? 1 : 0));
    assert(device.isBatteryMonitoringEnabled == enabled);
    assert(device.isMultitaskingSupported == (enabled && details));
    assert([device.model isEqual:enabled && ready ? PearDeviceName() : @"native-model"]);
    assert([device.systemVersion isEqual:enabled && ready ? PearIOSVersion() : @"native-version"]);
    assert([device.identifierForVendor isEqual:enabled && details && ready ? PearSyntheticVendorID()
        : [[NSUUID alloc] initWithUUIDString:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]]);
    NSInteger idiom = PearWantsPadIdiom() ? 1 : 0;
    assert(device.userInterfaceIdiom == (enabled && details && ready ? idiom : 5));
    assert(traits.userInterfaceIdiom == (enabled && forceTraits && ready ? idiom : 5));
}
int main(void) {
    @autoreleasepool {
        assert(getenv("PEAR_NO_DEVICE_SHIM") && getenv("PEAR_NO_NETWORK_SHIM"));
        assert(!NSClassFromString(@"UIDevice") && !NSClassFromString(@"UITraitCollection"));
        assert(!gInstalled && !gMockAccelerometer && !gMockGyro);
        PearDeviceShimInit();
        PearNetworkShimInit();
        PearInstallDeviceProperties();
        assert(!gInstalled && !gMockAccelerometer && !gMockGyro);
        BOOL ready = PearDeviceProfileGet()->status == PearDeviceProfileStatusReady;
        DeviceCase(NO, NO, NO, NO);
        DeviceCase(NO, NO, YES, NO);
        DeviceCase(NO, NO, NO, YES);
        DeviceCase(NO, NO, YES, YES);
        DeviceCase(NO, YES, YES, YES);
        DeviceCase(YES, NO, YES, YES);

        // Snapshot real networking IMPs, without creating any real request/session.
        Method realHeaders = class_getInstanceMethod(NSURLSessionConfiguration.class, @selector(HTTPAdditionalHeaders));
        Method realRequest = class_getInstanceMethod(NSMutableURLRequest.class, @selector(setAllHTTPHeaderFields:));
        IMP headersBefore = method_getImplementation(realHeaders), requestBefore = method_getImplementation(realRequest);
        IMP fixtureHeaders = Implementation(PearProfileConfigurationFixture.class, @selector(HTTPAdditionalHeaders));
        IMP fixtureSetter = Implementation(PearProfileConfigurationFixture.class, @selector(setHTTPAdditionalHeaders:));
        IMP fixtureRequest = Implementation(PearProfileRequestFixture.class, @selector(setAllHTTPHeaderFields:));
        IMP fixtureTask = Implementation(PearProfileSessionFixture.class, @selector(dataTaskWithRequest:));
        PearFixtureInstallNetworkShim();
        assert(gInstalled && gFixtureConfigurations == 2);
        assert(gKeepUA == (getenv("PEAR_NETWORK_KEEP_UA") != NULL));
        assert(gFixtureRequests == (ready ? 1u : 0u) && gFixtureSessions == (ready ? 1u : 0u));
        PearProfileConfigurationFixture *configuration = [PearProfileConfigurationFixture new];
        assert(!configuration.assumesHTTP3Capable);
        [configuration setAssumesHTTP3Capable:YES];
        assert(!configuration.assumesHTTP3Capable && !gFixtureH3Setters);
        assert((Implementation(PearProfileConfigurationFixture.class, @selector(HTTPAdditionalHeaders)) != fixtureHeaders) == ready);
        assert((Implementation(PearProfileConfigurationFixture.class, @selector(setHTTPAdditionalHeaders:)) != fixtureSetter) == ready);
        assert((Implementation(PearProfileRequestFixture.class, @selector(setAllHTTPHeaderFields:)) != fixtureRequest) == ready);
        assert((Implementation(PearProfileSessionFixture.class, @selector(dataTaskWithRequest:)) != fixtureTask) == ready);
        NSDictionary *headers = configuration.HTTPAdditionalHeaders;
        assert([headers[@"Other"] isEqual:@"native-header"]);
        if (ready) assert([headers[@"X-Device-Model"] isEqual:PearNetworkModelForTest()]);
        else assert([headers isEqual:@{ @"Other": @"native-header" }]);
        PearFixtureInstallNetworkShim(); // Existing one-time installer contract.
        assert(gFixtureConfigurations == 2);
        assert(method_getImplementation(realHeaders) == headersBefore && method_getImplementation(realRequest) == requestBefore);
        assert(PearDeviceShimDisabled() && getenv("PEAR_NO_NETWORK_SHIM"));
        assert(!NSClassFromString(@"UIDevice") && !NSClassFromString(@"UIApplication"));
        printf("{\"profileReady\":%s,\"HTTP3Off\":true,\"fixedBattery\":true,\"optInMultitasking\":true,"
               "\"profileGates\":true,\"optOutGates\":true,\"constructorsDisabled\":true}\n", ready ? "true" : "false");
    }
    return 0;
}
'''


def vendor_uuid(bundle, model):
    h1, h2 = 1469598103934665603, 1099511628211
    for byte in (bundle + ":" + model).encode("utf-8"):
        h1 = ((h1 ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        h2 = ((h2 ^ byte) * 1469598103934665603) & 0xFFFFFFFFFFFFFFFF
    return str(uuid.UUID(bytes=struct.pack("<QQ", h1, h2))).upper()


def wire_profile(values=DEFAULTS):
    return dict(schema=1, bundle=BUNDLE, systemName="iOS", **values,
                vendorIdentifier=vendor_uuid(BUNDLE, values["model"]))


def materialize(response):
    """Strict launcher-shaped fixture, NOT a runtime host client or Swift test."""
    if type(response) is not dict or response.get("ok") is not True:
        raise ValueError("device.get failed")
    value = response.get("value")
    if type(value) is not dict or set(value) != WIRE_FIELDS:
        raise ValueError("device.get must have exactly ten profile keys")
    if type(value["schema"]) is not int or value["schema"] != 1:
        raise ValueError("unsupported profile schema")
    if any(type(value[field]) is not str for field in VALUE_FIELDS):
        raise ValueError("non-string profile field")
    if value["bundle"] != BUNDLE or value["systemName"] != "iOS":
        raise ValueError("wrong bundle/systemName")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9,_-]{0,62}", value["model"], re.ASCII):
        raise ValueError("invalid model")
    name = value["name"]
    if not name or len(name.encode("utf-8")) > 127 or any(unicodedata.category(c) in ("Cc", "Cf") for c in name):
        raise ValueError("invalid name")
    if value["idiom"] not in ("phone", "pad"):
        raise ValueError("noncanonical idiom")
    for field in ("systemVersion", "darwinRelease"):
        if not re.fullmatch(r"[0-9]{1,4}(?:\.[0-9]{1,4}){0,2}", value[field], re.ASCII):
            raise ValueError("invalid " + field)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", value["systemBuild"], re.ASCII):
        raise ValueError("invalid build")
    if value["vendorIdentifier"] != vendor_uuid(BUNDLE, value["model"]):
        raise ValueError("wrong vendor UUID")
    return {**{env: value[field] for field, env in INPUTS.items()},
            "PEAR_DEVICE_PROFILE_SOURCE": "host-v1", "PEAR_DEVICE_PROFILE_BUNDLE": value["bundle"],
            "PEAR_DEVICE_VENDOR_UUID": value["vendorIdentifier"]}


def environment(root, values=None):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("PEAR_", "DYLD_")) and key not in ("HOME", "CFFIXED_USER_HOME", "TMPDIR")}
    home = root / "home"
    home.mkdir(parents=True, exist_ok=True)
    temporary = root / "tmp"
    temporary.mkdir(exist_ok=True)
    env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(temporary),
               PEAR_NO_DEVICE_SHIM="1", PEAR_NO_NETWORK_SHIM="1", PEAR_DEVICE_KERNEL="1")
    for key, value in (values or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


class Helper:
    def __init__(self, executable, root, values):
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors, env=environment(root, values))

    def read(self, command=None):
        assert self.process.stdin is not None and self.process.stdout is not None
        if command:
            self.process.stdin.write((command + "\n").encode())
            self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 8)[0]:
            raise AssertionError("profile helper timed out")
        line = self.process.stdout.readline()
        if not line:
            self.errors.seek(0)
            raise AssertionError("profile helper exited: " + self.errors.read().decode(errors="replace"))
        return json.loads(line.decode("utf-8", errors="surrogateescape"))

    def __enter__(self):
        return self

    def __exit__(self, *_):
        assert self.process.stdin is not None and self.process.stdout is not None
        try:
            if self.process.poll() is None:
                self.process.communicate(b"quit\n", timeout=5)
            assert self.process.returncode == 0, "helper failed with " + str(self.process.returncode)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
            self.errors.close()


def check_shims(result, profile):
    assert result["profile"] == profile, (result["profile"], profile)
    assert result["constructorsDisabled"] is True
    device = result["device"]
    supplied = {"User-Agent": "App-Supplied-UA", "X-Device-Model": "app-model",
                "X-OS-Version": "app-version", "Other": "preserved"}
    assert result["kept"] == supplied
    if profile["status"] != 1:
        assert all(value is None for key, value in device.items() if key != "pad")
        assert result["headers"] == {} and result["replaced"] == supplied
        assert result["macKept"] == {"User-Agent": "Macintosh; Mac OS X"}
        return
    assert device["modelIdentifier"] == profile["model"]
    for field in ("name", "systemVersion", "systemBuild", "darwinRelease"):
        assert device[field] == profile[field]
    assert device["pad"] == (profile["idiom"] == "pad")
    expected_vendor = profile["vendorIdentifier"] if profile["source"] == 1 else vendor_uuid(
        result["vendorSeedBundle"], profile["model"])
    assert device["vendorIdentifier"] == expected_vendor
    headers = result["headers"]
    assert headers["X-Device-Model"] == profile["model"]
    assert headers["X-OS-Version"] == profile["systemVersion"]
    token = "iPad" if profile["idiom"] == "pad" else "iPhone"
    assert headers["User-Agent"].endswith(f"({token}; iOS {profile['systemVersion']}; Scale/3.00)")
    assert result["replaced"] == {**supplied, "User-Agent": headers["User-Agent"]}
    assert result["macKept"] == headers


def exercise(executables, root, values, expected=None, invalid_field=None, shims=True):
    with Helper(executables[0], root, values) as helper:
        profile = helper.read()
        if expected is not None:
            assert profile == expected, (profile, expected)
        if invalid_field:
            assert profile["status"] != 1 and profile["invalidField"] == invalid_field, profile
            assert all(profile[field] is None for field in VALUE_FIELDS), profile
        assert helper.read("mutate") == profile
        assert helper.read("read") == profile
    if shims:
        with Helper(executables[1], root, values) as helper:
            result = helper.read()
            check_shims(result, profile)
            assert helper.read("mutate") == result, "Device/Network caches changed after environ mutation"
    return profile


def expected_profile(values=DEFAULTS, managed=False):
    return dict(source=1 if managed else 0, status=1, invalidField=None,
                bundle=BUNDLE if managed else None, systemName="iOS", **values,
                vendorIdentifier=vendor_uuid(BUNDLE, values["model"]) if managed else None)


def installer_tests(executables, root):
    managed = materialize({"ok": True, "value": wire_profile()})
    missing = dict(managed)
    del missing["PEAR_DEVICE_VENDOR_UUID"]
    cases = (
        ("legacy", {}, True),
        ("empty opt-outs", {"PEAR_NO_DEVICE_SHIM": "", "PEAR_NO_NETWORK_SHIM": ""}, True),
        ("legacy oversized", {"PEAR_DEVICE_NAME": "x" * 4096}, False),
        ("managed phone", managed, True),
        ("managed pad", materialize({"ok": True, "value": wire_profile(OVERRIDES)}), True),
        ("unknown source", {**managed, "PEAR_DEVICE_PROFILE_SOURCE": "host-v2", "PEAR_NETWORK_KEEP_UA": ""}, False),
        ("missing metadata", missing, False),
        ("malformed field", {**managed, "PEAR_DEVICE_MODEL": "invalid model"}, False),
    )
    for name, values, ready in cases:
        result = subprocess.run([str(executables[2])], env=environment(root, values),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        assert result.returncode == 0, name + ": " + result.stderr.decode(errors="replace")
        assert json.loads(result.stdout) == dict(profileReady=ready, HTTP3Off=True, fixedBattery=True,
                                                optInMultitasking=True, profileGates=True,
                                                optOutGates=True, constructorsDisabled=True), name
    print("PASS installer regressions: invalid profiles retain HTTP/3-off/fixed battery/opt-in multitasking; identity/header/trait gates and opt-outs preserved on fake classes", flush=True)


def runtime_tests(executables, root):
    exercise(executables, root, {}, expected_profile())
    exercise(executables, root, {"PEAR_PROFILE_TEST_EARLY": "1"}, expected_profile())
    exercise(executables, root, {key: "" for key in INPUTS.values()}, expected_profile())
    legacy = dict(OVERRIDES, model="Legacy model ?", systemVersion="v18.beta", systemBuild="build / legacy")
    legacy_env = {env: legacy[field] for field, env in INPUTS.items()}
    legacy_env["PEAR_DEVICE_IDIOM"] = "iPaD"
    exercise(executables, root, legacy_env, expected_profile(legacy))
    for idiom, normalized in (("iPhOnE", "phone"), ("unknown", "phone"), ("PAD", "pad")):
        exercise(executables, root, {"PEAR_DEVICE_IDIOM": idiom},
                 expected_profile(dict(DEFAULTS, idiom=normalized)))
    exercise(executables, root, {"PEAR_DEVICE_MODEL": "x" * 4095},
             expected_profile(dict(DEFAULTS, model="x" * 4095)))
    exercise(executables, root, {"PEAR_DEVICE_MODEL": "x" * 4096}, invalid_field="PEAR_DEVICE_MODEL")
    # Preserve legacy raw bytes without ever feeding malformed UTF-8 to Foundation.
    exercise(executables, root, {"PEAR_DEVICE_NAME": "legacy-\udcff"},
             expected_profile(dict(DEFAULTS, name="legacy-\udcff")), shims=False)
    managed = materialize({"ok": True, "value": wire_profile()})
    exercise(executables, root, managed, expected_profile(managed=True))
    exercise(executables, root, {**managed, "PEAR_PROFILE_TEST_EARLY": "1"}, expected_profile(managed=True))
    custom = materialize({"ok": True, "value": wire_profile(OVERRIDES)})
    exercise(executables, root, custom, expected_profile(OVERRIDES, managed=True))
    # Runtime must CONSUME a supplied UUID, not regenerate it from its own bundle.
    explicit_uuid = "00112233-4455-6677-8899-AABBCCDDEEFF"
    exercise(executables, root, {**custom, "PEAR_DEVICE_VENDOR_UUID": explicit_uuid.lower()},
             {**expected_profile(OVERRIDES, managed=True), "vendorIdentifier": explicit_uuid})
    for alias in ("iPaD", "PAD"):
        exercise(executables, root, {**custom, "PEAR_DEVICE_IDIOM": alias}, expected_profile(OVERRIDES, managed=True))
    bad = [
        ("PEAR_DEVICE_PROFILE_SOURCE", "host-v2"), ("PEAR_DEVICE_PROFILE_SOURCE", ""),
        ("PEAR_DEVICE_PROFILE_BUNDLE", ""), ("PEAR_DEVICE_PROFILE_BUNDLE", "x" * 256),
        ("PEAR_DEVICE_PROFILE_BUNDLE", "bad\nmetadata"), ("PEAR_DEVICE_PROFILE_BUNDLE", "bad-\udcff"),
        ("PEAR_DEVICE_VENDOR_UUID", "bad"), ("PEAR_DEVICE_VENDOR_UUID", explicit_uuid + "0"),
        ("PEAR_DEVICE_VENDOR_UUID", "00112233_4455-6677-8899-AABBCCDDEEFF"),
        ("PEAR_DEVICE_VENDOR_UUID", "G0112233-4455-6677-8899-AABBCCDDEEFF"),
        ("PEAR_DEVICE_MODEL", ""), ("PEAR_DEVICE_MODEL", "1phone"), ("PEAR_DEVICE_MODEL", "iPhone 15"),
        ("PEAR_DEVICE_MODEL", "iPhöne"), ("PEAR_DEVICE_MODEL", "i" * 64),
        ("PEAR_DEVICE_NAME", ""), ("PEAR_DEVICE_NAME", "a" * 128), ("PEAR_DEVICE_NAME", "🍐" * 32),
        ("PEAR_DEVICE_NAME", "bad\tname"), ("PEAR_DEVICE_NAME", "bad\x85name"),
        ("PEAR_DEVICE_NAME", "bad\u202ename"), ("PEAR_DEVICE_NAME", "bad\U000e0001name"),
        ("PEAR_DEVICE_NAME", "bad-\udcff"), ("PEAR_DEVICE_NAME", "bad-\udced\udca0\udc80"),
        ("PEAR_DEVICE_IDIOM", ""), ("PEAR_DEVICE_IDIOM", "watch"), ("PEAR_DEVICE_IDIOM", "x" * 5000),
        ("PEAR_FAKE_IOS_VERSION", ""), ("PEAR_FAKE_IOS_VERSION", "16..1"),
        ("PEAR_FAKE_IOS_VERSION", "1.2.3.4"), ("PEAR_FAKE_IOS_VERSION", "12345"),
        ("PEAR_FAKE_IOS_VERSION", "1.２"), ("PEAR_FAKE_IOS_BUILD", ""),
        ("PEAR_FAKE_IOS_BUILD", ".20A"), ("PEAR_FAKE_IOS_BUILD", "20 A"),
        ("PEAR_FAKE_IOS_BUILD", "A" * 65), ("PEAR_FAKE_DARWIN", "22."),
        ("PEAR_FAKE_DARWIN", "1.2.3.4"), ("PEAR_FAKE_DARWIN", "x" * 5000),
    ]
    for key, value in bad:
        exercise(executables, root, {**managed, key: value}, invalid_field=key)
    for key in managed:
        incomplete = dict(managed)
        del incomplete[key]
        exercise(executables, root, incomplete, invalid_field=key)
    for key in ("PEAR_DEVICE_PROFILE_BUNDLE", "PEAR_DEVICE_VENDOR_UUID"):
        exercise(executables, root, {key: managed[key]}, invalid_field="PEAR_DEVICE_PROFILE_SOURCE")
    # Boundary cases use the host grammar, not an arbitrary device allowlist.
    boundaries = dict(model="A" + "x" * 62, name="🍐" * 31 + "abc", idiom="phone",
                      systemVersion="9999.0000.1234", systemBuild="B" * 64, darwinRelease="1")
    boundary_env = materialize({"ok": True, "value": wire_profile(boundaries)})
    exercise(executables, root, boundary_env, expected_profile(boundaries, managed=True))
    # Explicitly absent kernel opt-in: C model paths still work; kernel does not.
    no_kernel = dict(managed)
    no_kernel["PEAR_DEVICE_KERNEL"] = None
    with Helper(executables[1], root, no_kernel) as helper:
        check_shims(helper.read(), expected_profile(managed=True))
    print("PASS runtime: defaults/legacy/managed, UTF-8/bounds/rejections, early races, immutable C/Device/Network caches", flush=True)


def frame(value):
    payload = plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
    assert 0 < len(payload) <= MAX_FRAME
    return struct.pack(">I", len(payload)) + payload


def exact(connection, length):
    value = bytearray()
    while len(value) < length:
        data = connection.recv(length - len(value))
        if not data:
            raise ValueError("truncated plist frame")
        value.extend(data)
    return bytes(value)


def receive(connection):
    length, = struct.unpack(">I", exact(connection, 4))
    if not 0 < length <= MAX_FRAME:
        raise ValueError("invalid plist frame length")
    payload = exact(connection, length)
    if not payload.startswith(b"bplist00"):
        raise ValueError("not a binary plist")
    value = plistlib.loads(payload)
    if type(value) is not dict:
        raise ValueError("not a dictionary")
    return value


def request(path, operation, token=TOKEN, version=1):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall(frame(dict(op=operation, token=token, version=version)))
        return receive(connection)


def fetch(path):
    ping = request(path, "ping")
    if ping != dict(ok=True, service="pear-host", version=1, bundle=BUNDLE):
        raise ValueError("invalid authenticated ping")
    return materialize(request(path, "device.get"))


class Peer:
    def __init__(self, root, response=None, raw=None):
        self.path = root / "peer.sock"
        self.response = response if response is not None else {"ok": True, "value": wire_profile()}
        self.raw = raw
        self.errors = []
        self.requests = []
        self.stopped = threading.Event()

    def __enter__(self):
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        self.listener.listen(4)
        self.listener.settimeout(0.05)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        return self

    def serve(self):
        try:
            while not self.stopped.is_set():
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(2)
                    message = receive(connection)
                    self.requests.append(message)
                    if message.get("token") != TOKEN or type(message.get("version")) is not int or message["version"] != 1:
                        response = {"ok": False, "error": "unauthorized/version"}
                    elif message.get("op") == "ping":
                        response = dict(ok=True, service="pear-host", version=1, bundle=BUNDLE)
                    else:
                        assert message["op"] == "device.get", "unexpected operation: " + repr(message)
                        if self.raw is not None:
                            connection.sendall(self.raw)
                            continue
                        response = self.response
                    connection.sendall(frame(response))
        except Exception as error:
            self.errors.append(error)

    def close(self):
        self.stopped.set()
        self.thread.join(timeout=3)
        self.listener.close()
        self.path.unlink(missing_ok=True)
        assert not self.thread.is_alive(), "peer failed to stop"
        assert not self.errors, self.errors

    def __exit__(self, *_):
        self.close()


def loss_test(executables, root, path, stop):
    values = fetch(path)
    values.update(PEAR_HOST_SOCKET=str(path), PEAR_HOST_TOKEN=TOKEN)
    with Helper(executables[0], root, values) as plain, Helper(executables[1], root, values) as shims:
        first = plain.read()
        result = shims.read()
        check_shims(result, first)
        stop()
        # Abrupt host loss may leave a stale socket inode. Only an unreachable
        # service matters to runtime cache independence, not pathname cleanup.
        try:
            request(path, "ping")
        except (OSError, ValueError):
            pass
        else:
            raise AssertionError("host still responds after loss")
        assert plain.read("read") == first and shims.read("read") == result
        assert plain.read("mutate") == first and shims.read("mutate") == result


def peer_tests(executables, root):
    with Peer(root) as peer:
        assert request(peer.path, "ping", token="wrong")["ok"] is False
        assert request(peer.path, "device.get", version=2)["ok"] is False
        values = fetch(peer.path)
        exercise(executables, root, values, expected_profile(managed=True))
    peer = Peer(root)
    peer.__enter__()
    try:
        loss_test(executables, root, peer.path, peer.close)
    finally:
        if peer.thread.is_alive():
            peer.close()
    invalid = [{"ok": False, "error": "unavailable"}, {"ok": True}, {"ok": True, "value": []}]
    profile = wire_profile()
    for field in WIRE_FIELDS:
        missing = dict(profile)
        del missing[field]
        invalid.append(dict(ok=True, value=missing))
    for field, bad in (("schema", 2), ("schema", True), ("schema", 1.0), ("extra", "field"),
                       ("bundle", "wrong.bundle"), ("systemName", "macOS"), ("model", "iPhone bad"),
                       ("model", "A" * 64), ("name", "bad\nname"), ("name", "🍐" * 32),
                       ("idiom", "iPad"), ("systemVersion", "1..2"), ("systemBuild", " build"),
                       ("darwinRelease", "12345"), ("vendorIdentifier", "not-a-UUID"),
                       ("vendorIdentifier", "00112233-4455-6677-8899-AABBCCDDEEFF"), ("name", b"UTF8?")):
        invalid.append(dict(ok=True, value={**profile, field: bad}))
    for response in invalid:
        with Peer(root, response=response) as peer:
            try:
                fetch(peer.path)
            except ValueError:
                pass
            else:
                raise AssertionError("accepted malformed host profile: " + repr(response))
    for raw in (struct.pack(">I", MAX_FRAME + 1), b"\0\0\0\0", b"\0\0\0\x08notplist",
                b"\0\0\0\x10bplist00", frame(["not a dictionary"])):
        with Peer(root, raw=raw) as peer:
            try:
                fetch(peer.path)
            except (ValueError, plistlib.InvalidFileException):
                pass
            else:
                raise AssertionError("accepted malformed host frame")
    print("PASS deterministic peers: authenticated ping/device.get, exact schema, malformed frames/profiles, host loss after capture", flush=True)


class CLIHost:
    def __init__(self, executable, root, values):
        self.executable, self.root, self.values = executable, root, values
        self.path = root / "ipc/host.sock"
        self.process = None

    def start(self):
        self.path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.path.parent.chmod(0o700)
        data = self.root / "data"
        data.mkdir(parents=True, exist_ok=True)
        env = environment(self.root, self.values)
        env["PEAR_HOST_TOKEN"] = TOKEN
        self.log = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(self.executable), "host-service", "--socket", str(self.path),
                                         "--bundle", BUNDLE, "--data", str(data)],
                                        env=env, stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 5
        while not self.path.exists():
            if self.process.poll() is not None or time.monotonic() >= deadline:
                self.log.seek(0)
                raise AssertionError("CLI host failed to start: " + self.log.read().decode(errors="replace"))
            time.sleep(0.01)

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
            self.log.close()
            self.process = None


def cli_tests(executables, executable, root):
    for index, values in enumerate((DEFAULTS, OVERRIDES)):
        inputs = {env: values[field] for field, env in INPUTS.items()}
        if index:
            inputs["PEAR_DEVICE_IDIOM"] = "iPaD"  # Host normalizes public aliases.
        host = CLIHost(executable, root / str(index), inputs)
        try:
            host.start()
            assert request(host.path, "ping", token="wrong")["ok"] is False
            assert request(host.path, "device.get", version=2)["ok"] is False
            materialized = fetch(host.path)
            assert materialized == materialize({"ok": True, "value": wire_profile(values)}), (
                "CLI device.get did not apply the six startup inputs; launcher/CLI wiring may be pending", materialized)
            exercise(executables, root / str(index), materialized, expected_profile(values, managed=True))
            loss_test(executables, root / str(index), host.path, host.close)
            print("PASS supplied CLI: " + ("defaults" if index == 0 else "overrides") +
                  ", authenticated profile/UUID and post-host-loss caches", flush=True)
        finally:
            host.close()
    print("PASS supplied CLI: normalized defaults/overrides, host UUID algorithm, authenticated handoff, host loss/cache stability", flush=True)


def build(root):
    include = root / "include/UIKit"
    include.mkdir(parents=True)
    (include / "UIKit.h").write_text("#import <CoreGraphics/CoreGraphics.h>\n")
    (root / "support.h").write_text(SUPPORT)
    source = root / "profile.c"
    source.write_text('#include "support.h"\n')
    shims = root / "shims.mm"
    shims.write_text(SHIMS)
    installers = root / "installers.mm"
    installers.write_text(INSTALLERS)
    for filename, function, boundary, output in (
        ("DeviceShim.mm", "PearInstallDeviceProperties", "\n#pragma mark - Foundation version", "device-installer.inc"),
        ("NetworkShim.mm", "PearInstallNetworkShim", "\n__attribute__((constructor))", "network-installer.inc"),
    ):
        text = (ROOT / "runtime" / filename).read_text()
        declaration = "static void " + function + "(void) {"
        assert text.count(declaration) == 1, "installer extraction requires a unique definition"
        start = text.index(declaration)
        (root / output).write_text(text[start:text.index(boundary, start)])
    strict_c_object = root / "profile-c.o"
    profile_object = root / "profile.o"
    common = ["xcrun", "--sdk", "macosx", "clang", "-x", "c", "-std=c11", "-Wall", "-Wextra",
              "-Werror", "-Wno-unused-parameter", "-I" + str(ROOT / "runtime/include")]
    subprocess.run(common + ["-c", str(ROOT / "runtime/DeviceProfile.mm"), "-o", str(strict_c_object)],
                   check=True, timeout=60)
    subprocess.run(["xcrun", "--sdk", "macosx", "clang++", "-x", "c++", "-std=c++17",
                    "-Wall", "-Wextra", "-Werror", "-I" + str(ROOT / "runtime/include"),
                    "-c", str(ROOT / "runtime/DeviceProfile.mm"), "-o", str(profile_object)],
                   check=True, timeout=60)
    # A strict dependency audit catches accidental ObjC/Foundation/IPC/file access
    # even when an early-access test happens not to exercise the offending path.
    allowed = {"___stack_chk_fail", "___stack_chk_guard", "___memcpy_chk", "_getenv", "_memcpy",
               "_pthread_once", "_strcmp", "_strlen", "_strnlen"}
    for artifact in (strict_c_object, profile_object):
        symbols = subprocess.check_output(["nm", "-u", str(artifact)], text=True, timeout=10)
        assert {line.split()[-1] for line in symbols.splitlines() if line.strip()} <= allowed, symbols
    plain = root / "profile"
    subprocess.run(common + [str(source), "-x", "none", str(profile_object), "-pthread", "-o", str(plain)],
                   check=True, timeout=60)
    libraries = subprocess.check_output(["otool", "-L", str(plain)], text=True, timeout=10)
    assert "Foundation" not in libraries and "UIKit" not in libraries and "libobjc" not in libraries, libraries
    shim_binary = root / "shims"
    installer_binary = root / "installers"
    shim_command = ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks",
                    "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-local-typedef",
                    "-I" + str(root / "include"), "-I" + str(ROOT / "runtime/include"),
                    "-I" + str(ROOT / "runtime"), "-framework", "Foundation", "-framework", "IOKit"]
    for source_file, binary in ((shims, shim_binary), (installers, installer_binary)):
        subprocess.run(shim_command + [str(source_file), str(profile_object), "-o", str(binary)],
                       check=True, timeout=60)
        libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True, timeout=10)
        assert "UIKit" not in libraries, libraries
    print("PASS build/dependency audit: strict C/C++ helper, no ObjC/Foundation/IPC/file symbols; C caller and production shims link without UIKit", flush=True)
    return plain, shim_binary, installer_binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", nargs="?", type=Path, help="already-built CLI with host-service/device.get")
    args = parser.parse_args()
    if args.host:
        args.host = args.host.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="pear-profile-", dir="/tmp") as directory:
        root = Path(directory)
        executables = build(root)
        installer_tests(executables, root)
        runtime_tests(executables, root)
        peer_tests(executables, root)
        if args.host:
            cli_tests(executables, args.host, root / "cli")
        else:
            print("SKIP real CLI integration (supply its executable as the positional argument)", flush=True)
    print("All requested device-profile smoke tests passed.", flush=True)


if __name__ == "__main__":
    main()
