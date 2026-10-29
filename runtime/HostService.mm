// HostService.mm
//
// Cold-state client for pear-host: a big-endian length followed by a binary
// plist dictionary. Configuration is fixed on first use; a configured but
// unavailable host must never select the legacy local store.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <poll.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <time.h>
#import <unistd.h>
#import "PearRuntime.h"

// Keep wire limits/version in sync with HostServiceProtocol.swift.
static const NSUInteger kPearHostMaximumFrame = 1 << 20;
static const NSUInteger kPearHostMaximumKey = 1024;
static const uint64_t kPearHostMainBudget = 100 * NSEC_PER_MSEC;
static const uint64_t kPearHostWorkerBudget = 500 * NSEC_PER_MSEC;
static const uint64_t kPearHostFailureBackoff = 250 * NSEC_PER_MSEC;

static BOOL gHostConfigured;
static NSString *gHostSocket;
static NSString *gHostToken;
static dispatch_semaphore_t gHostLock;
// All connection state is protected by gHostLock.
static int gHostFD = -1;
static uint64_t gHostRetryAfter;

static uint64_t PearHostNow(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

uint64_t PearHostDeadline(void) {
    return PearHostNow() + ([NSThread isMainThread] ? kPearHostMainBudget : kPearHostWorkerBudget);
}

BOOL PearHostAcquireUntil(dispatch_semaphore_t gate, uint64_t deadline) {
    uint64_t now = PearHostNow();
    if (now >= deadline || dispatch_semaphore_wait(gate,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline - now))) != 0) return NO;
    if (PearHostNow() >= deadline) {
        dispatch_semaphore_signal(gate);
        return NO;
    }
    return YES;
}

BOOL PearHostIsConfigured(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHostLock = dispatch_semaphore_create(1);
        const char *path = getenv("PEAR_HOST_SOCKET");
        // Presence, not validity, selects the exclusive host-writer mode.
        gHostConfigured = path != NULL;
        if (!path) return;
        struct sockaddr_un address;
        size_t length = strnlen(path, sizeof(address.sun_path));
        if (length == 0 || length >= sizeof(address.sun_path) || path[0] != '/') return;
        NSString *socketPath = [[NSString alloc] initWithBytes:path length:length
                                                   encoding:NSUTF8StringEncoding];
        if (!socketPath || [socketPath hasSuffix:@"/"] ||
            [@[@".", @".."] containsObject:socketPath.lastPathComponent]) return;
        gHostSocket = socketPath;
        const char *token = getenv("PEAR_HOST_TOKEN");
        if (!token) return;
        size_t tokenLength = strnlen(token, kPearHostMaximumFrame + 1);
        if (tokenLength == 0 || tokenLength > kPearHostMaximumFrame) return;
        gHostToken = [[NSString alloc] initWithBytes:token length:tokenLength
                                          encoding:NSUTF8StringEncoding];
    });
    return gHostConfigured;
}

static void PearHostResetLocked(void) {
    if (gHostFD >= 0) close(gHostFD);
    gHostFD = -1;
}

static BOOL PearHostWait(int fd, short events, uint64_t deadline) {
    while (true) {
        uint64_t now = PearHostNow();
        if (now >= deadline) return NO;
        int milliseconds = (int)MIN((deadline - now + NSEC_PER_MSEC - 1) / NSEC_PER_MSEC,
                                    (uint64_t)INT_MAX);
        struct pollfd descriptor = { fd, events, 0 };
        int result = poll(&descriptor, 1, milliseconds);
        if (result > 0) {
            if (descriptor.revents & POLLNVAL) return NO;
            if (descriptor.revents & (events | POLLHUP | POLLERR)) return YES;
        } else if (result < 0 && errno != EINTR) {
            return NO;
        }
    }
}

static BOOL PearHostConnectLocked(uint64_t deadline) {
    if (PearHostNow() >= deadline) return NO;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int enabled = 1;
    int flags = fcntl(fd, F_GETFL);
    int descriptorFlags = fcntl(fd, F_GETFD);
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0 ||
        flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 ||
        descriptorFlags < 0 || fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) != 0) {
        close(fd);
        return NO;
    }

    struct sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    const char *path = gHostSocket.UTF8String;
    memcpy(address.sun_path, path, strlen(path) + 1);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result != 0) {
        int code = errno;
        if ((code != EINPROGRESS && code != EINTR && code != EAGAIN && code != EWOULDBLOCK) ||
            !PearHostWait(fd, POLLOUT, deadline)) {
            close(fd);
            return NO;
        }
        int socketError = 0;
        socklen_t size = sizeof(socketError);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) != 0 || socketError != 0) {
            close(fd);
            return NO;
        }
    }
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || uid != getuid() || PearHostNow() >= deadline) {
        close(fd);
        return NO;
    }
    gHostFD = fd;
    return YES;
}

static BOOL PearHostConnectionReusableLocked(uint64_t deadline) {
    // The server expires idle connections. Detect EOF (or unsolicited bytes)
    // before sending, when reconnecting is still unambiguously safe.
    uint8_t byte;
    while (PearHostNow() < deadline) {
        ssize_t count = recv(gHostFD, &byte, 1, MSG_PEEK);
        if (count < 0 && errno == EINTR) continue;
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
    }
    return NO;
}

static BOOL PearHostWrite(int fd, NSData *frame, size_t *sent, uint64_t deadline) {
    const uint8_t *bytes = (const uint8_t *)frame.bytes;
    while (*sent < frame.length) {
        if (!PearHostWait(fd, POLLOUT, deadline)) return NO;
        ssize_t count = send(fd, bytes + *sent, frame.length - *sent, 0);
        if (count > 0) *sent += (size_t)count;
        else if (count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) return NO;
    }
    return YES;
}

static BOOL PearHostRead(int fd, void *buffer, size_t length, uint64_t deadline) {
    size_t offset = 0;
    while (offset < length) {
        if (!PearHostWait(fd, POLLIN, deadline)) return NO;
        ssize_t count = recv(fd, (uint8_t *)buffer + offset, length - offset, 0);
        if (count > 0) offset += (size_t)count;
        else if (count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) return NO;
    }
    return YES;
}

// Reject binary-plist nulls/non-string dictionary keys as well as excessive
// nesting before serialization or exposing a decoded value to a caller.
static BOOL PearHostValidPlist(id value, NSUInteger depth) {
    if (!value || depth > 128) return NO;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSDate.class]) return YES;
    if ([value isKindOfClass:NSData.class]) return [value length] <= kPearHostMaximumFrame;
    if ([value isKindOfClass:NSArray.class]) {
        if ([value count] > kPearHostMaximumFrame) return NO;
        for (id item in value) if (!PearHostValidPlist(item, depth + 1)) return NO;
        return YES;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        if ([value count] > kPearHostMaximumFrame) return NO;
        for (id key in value) {
            if (![key isKindOfClass:NSString.class] || !PearHostValidPlist(value[key], depth + 1)) return NO;
        }
        return YES;
    }
    return NO;
}

static BOOL PearHostBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL PearHostValidResponse(NSDictionary *response, NSString *operation) {
    id ok = response[@"ok"];
    if (!PearHostBoolean(ok)) return NO;
    if (![ok boolValue]) return [response[@"error"] isKindOfClass:NSString.class];
    if (![operation isKindOfClass:NSString.class]) return YES;
    if ([operation isEqualToString:@"ping"]) {
        id version = response[@"version"];
        return [response[@"service"] isEqual:@"pear-host"] &&
            [response[@"bundle"] isKindOfClass:NSString.class] &&
            [version isKindOfClass:NSNumber.class] && !PearHostBoolean(version) &&
            !CFNumberIsFloatType((__bridge CFNumberRef)version) && [version isEqualToNumber:@1];
    }
    if ([operation isEqualToString:@"kv.get"]) {
        id found = response[@"found"];
        return PearHostBoolean(found) && ([found boolValue] == (response[@"value"] != nil));
    }
    if ([operation isEqualToString:@"kv.all"]) {
        return [response[@"value"] isKindOfClass:NSDictionary.class];
    }
    return YES;
}

static NSDictionary *PearHostCallLocked(NSDictionary *request, uint64_t deadline) {
    if (PearHostNow() < gHostRetryAfter || PearHostNow() >= deadline) return nil;
    NSMutableDictionary *authenticated = [request mutableCopy];
    authenticated[@"version"] = @1;
    authenticated[@"token"] = gHostToken;
    NSData *payload = nil;
    @try {
        if (!PearHostValidPlist(authenticated, 0) ||
            ![NSPropertyListSerialization propertyList:authenticated
                                     isValidForFormat:NSPropertyListBinaryFormat_v1_0]) return nil;
        payload = [NSPropertyListSerialization dataWithPropertyList:authenticated
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0 error:NULL];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (!payload || payload.length == 0 || payload.length > kPearHostMaximumFrame ||
        PearHostNow() >= deadline) return nil;
    uint32_t length = htonl((uint32_t)payload.length);
    NSMutableData *frame = [NSMutableData dataWithBytes:&length length:sizeof(length)];
    [frame appendData:payload];

    BOOL reused = gHostFD >= 0;
    if (reused && !PearHostConnectionReusableLocked(deadline)) {
        PearHostResetLocked();
        reused = NO;
    }
    if (gHostFD < 0 && !PearHostConnectLocked(deadline)) goto failed;
    {
        size_t sent = 0;
        if (!PearHostWrite(gHostFD, frame, &sent, deadline)) {
            PearHostResetLocked();
            // Even a partial header may have reached the server. In particular,
            // never replay a mutation after a lost ACK. Only zero-byte sends on
            // an old connection may be retried, once, within the same deadline.
            if (!reused || sent != 0 || !PearHostConnectLocked(deadline) ||
                !PearHostWrite(gHostFD, frame, &sent, deadline)) goto failed;
        }
        uint32_t header;
        if (!PearHostRead(gHostFD, &header, sizeof(header), deadline)) goto failed;
        NSUInteger size = ntohl(header);
        if (size == 0 || size > kPearHostMaximumFrame) goto failed;
        NSMutableData *data = [NSMutableData dataWithLength:size];
        if (!PearHostRead(gHostFD, data.mutableBytes, size, deadline)) goto failed;
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id object = nil;
        @try {
            object = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                                format:&format error:NULL];
        } @catch (__unused NSException *exception) {
            goto failed;
        }
        if (format != NSPropertyListBinaryFormat_v1_0 || ![object isKindOfClass:NSDictionary.class] ||
            !PearHostValidPlist(object, 0) || !PearHostValidResponse(object, request[@"op"]) ||
            PearHostNow() >= deadline) goto failed;
        gHostRetryAfter = 0;
        // Auth/version errors can close the peer. Return the server's error,
        // but never leave an errored connection available for another request.
        if (![object[@"ok"] boolValue]) PearHostResetLocked();
        return object;
    }
failed:
    PearHostResetLocked();
    gHostRetryAfter = PearHostNow() + kPearHostFailureBackoff;
    return nil;
}

NSDictionary *PearHostCall(NSDictionary *request) {
    return PearHostCallUntil(request, PearHostDeadline());
}

NSDictionary *PearHostCallUntil(NSDictionary *request, uint64_t deadline) {
    deadline = MIN(deadline, PearHostDeadline());
    if (!PearHostIsConfigured() || !gHostSocket || !gHostToken ||
        ![request isKindOfClass:NSDictionary.class] || !PearHostAcquireUntil(gHostLock, deadline)) return nil;
    @try {
        return PearHostCallLocked(request, deadline);
    } @finally {
        dispatch_semaphore_signal(gHostLock);
    }
}

static BOOL PearHostValidKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    NSUInteger length = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return length > 0 && length <= kPearHostMaximumKey;
}

BOOL PearHostKVGet(NSString *key, id __autoreleasing *value) {
    if (value) *value = nil;
    if (!PearHostValidKey(key)) return NO;
    NSDictionary *response = PearHostCall(@{ @"op": @"kv.get", @"key": key });
    if (![response[@"ok"] boolValue]) return NO;
    if (value) *value = response[@"value"];
    return YES;
}

BOOL PearHostKVSet(NSString *key, id value) {
    if (!PearHostValidKey(key)) return NO;
    NSMutableDictionary *request = [@{ @"op": @"kv.set", @"key": key } mutableCopy];
    if (value) request[@"value"] = value; // Omission deletes; NSNull is not a plist value.
    return [PearHostCall(request)[@"ok"] boolValue];
}

NSDictionary *PearHostKVAll(void) {
    NSDictionary *response = PearHostCall(@{ @"op": @"kv.all" });
    return [response[@"ok"] boolValue] ? response[@"value"] : nil;
}
