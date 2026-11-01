#!/usr/bin/env python3
"""Foundation-only IPC/KV and ubiquity-token tests; all data stays in a temporary dir.

Usage: python3 scripts/runtime-client-smoke.py [path/to/pearsilicon]
The optional executable is invoked ONLY as `host-service`, never as a GUI/app.
Without it, deterministic adversarial peers still exercise the production client.
Requires macOS, Xcode/CLT clang++, and Python 3's standard library; no packages.
"""

import argparse
import base64
import datetime
import os
from pathlib import Path
import plistlib
import select
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
from typing import Optional


MAX_FRAME = 1_048_576
TOKEN = "runtime-client-smoke-token"
BUNDLE = "com.pearsilicon.runtime-client-smoke"
ROOT = Path(__file__).resolve().parents[1]

# Import the exact production sources/header. Only UIKit's otherwise unused
# import is stubbed in the test include path; no production SDK imports change.
# Disable the Cloud constructor before exec. Install KV methods, and opt into
# the local ubiquity surface only for token checks. No real iCloud store/account
# is instantiated; KV accessors are invoked through their IMPs with nil self.
HARNESS = r'''
#import <Foundation/Foundation.h>
#import <signal.h>
#import <sys/time.h>
#import "HostService.mm"
#import "CloudShim.mm"

void PearLog(NSString *format, ...) {}
static void Interrupted(int signal) {}

static dispatch_group_t TestWorkers(void) {
    static dispatch_group_t group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ group = dispatch_group_create(); });
    return group;
}
static NSDictionary *gTestAsyncResult;

static NSDictionary *Execute(NSDictionary *command) {
    NSString *method = command[@"method"];
    NSString *key = command[@"key"];
    id value = command[@"value"];
    if ([method isEqual:@"configured"]) return @{ @"configured": @(PearHostIsConfigured()) };
    if ([method isEqual:@"gate.hold"]) {
        dispatch_semaphore_t gate = [command[@"gate"] isEqual:@"cloud"] ? PearHostKVGate() : gHostLock;
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        dispatch_group_enter(TestWorkers());
        // Utility QoS may coalesce a 60 ms fixture timer past 100 ms on macOS.
        // Keep fixture timing precise; this is still a non-main worker.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(ready);
            dispatch_semaphore_t timer = dispatch_semaphore_create(0);
            dispatch_semaphore_wait(timer, dispatch_time(DISPATCH_TIME_NOW,
                [command[@"milliseconds"] longLongValue] * NSEC_PER_MSEC));
            dispatch_semaphore_signal(gate);
            dispatch_group_leave(TestWorkers());
        });
        if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) abort();
        return @{ @"success": @YES };
    }
    if ([method isEqual:@"async.start"]) {
        gTestAsyncResult = nil;
        dispatch_group_enter(TestWorkers());
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { gTestAsyncResult = Execute(command[@"command"]); }
            dispatch_group_leave(TestWorkers());
        });
        return @{ @"success": @YES };
    }
    if ([method isEqual:@"gate.wait"] || [method isEqual:@"async.wait"]) {
        if (dispatch_group_wait(TestWorkers(), dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) abort();
        return [method isEqual:@"async.wait"] ? gTestAsyncResult : @{ @"success": @YES };
    }
    if ([method isEqual:@"cloud.cache"]) {
        if (!PearHostAcquireUntil(PearHostKVGate(), PearHostDeadline())) return @{ @"success": @NO };
        @try {
            PearCollectRejectedHostWrites();
            return @{ @"success": @YES, @"value": [gKV copy] ?: @{},
                      @"unconfirmed": @(gHostUnconfirmedWrites.count) };
        } @finally {
            dispatch_semaphore_signal(PearHostKVGate());
        }
    }
    if ([method isEqual:@"environment"]) {
        for (NSString *name in @[@"PEAR_HOST_SOCKET", @"PEAR_HOST_TOKEN"]) {
            NSString *replacement = command[name];
            if (replacement) setenv(name.UTF8String, replacement.UTF8String, 1);
            else unsetenv(name.UTF8String);
        }
        return @{ @"configured": @(PearHostIsConfigured()) };
    }
    if ([method isEqual:@"flags"]) {
        int enabled = 0;
        socklen_t size = sizeof(enabled);
        uid_t uid = (uid_t)-1;
        gid_t gid;
        getsockopt(gHostFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size);
        getpeereid(gHostFD, &uid, &gid);
        return @{ @"nosigpipe": @(enabled), @"uid": @(uid),
                  @"nonblocking": @((fcntl(gHostFD, F_GETFL) & O_NONBLOCK) != 0),
                  @"cloexec": @((fcntl(gHostFD, F_GETFD) & FD_CLOEXEC) != 0) };
    }
    if ([method isEqual:@"lockwait"]) {
        dispatch_semaphore_wait(gHostLock, DISPATCH_TIME_FOREVER);
        NSDictionary *response = PearHostCall(@{ @"op": @"ping" });
        dispatch_semaphore_signal(gHostLock);
        return @{ @"success": @(response != nil) };
    }
    if ([method isEqual:@"call"]) {
        NSDictionary *response = PearHostCall(command[@"request"]);
        return response ? @{ @"success": @YES, @"response": response } : @{ @"success": @NO };
    }
    if ([method isEqual:@"get"]) {
        id result = @"out parameter must be cleared";
        BOOL success = PearHostKVGet(key, &result);
        return result ? @{ @"success": @(success), @"value": result } : @{ @"success": @(success) };
    }
    if ([method isEqual:@"set"]) return @{ @"success": @(PearHostKVSet(key, value)) };
    if ([method isEqual:@"all"]) {
        NSDictionary *result = PearHostKVAll();
        return result ? @{ @"success": @YES, @"value": result } : @{ @"success": @NO };
    }
    if ([method isEqual:@"cloud.identity"]) {
        PearInstallUbiquityContainer();
        id token = NSFileManager.defaultManager.ubiquityIdentityToken;
        if (![token isKindOfClass:NSData.class]) return @{ @"isData": @NO };
        NSError *error = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:token
            requiringSecureCoding:YES error:&error];
        NSData *restored = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:NSData.class
            fromData:archive error:&error] : nil;
        return @{ @"isData": @YES,
                  @"mutable": @([token isKindOfClass:NSMutableData.class]),
                  @"stable": @([token isEqual:NSFileManager.defaultManager.ubiquityIdentityToken]),
                  @"copyEqual": @([token isEqual:[token copy]]),
                  @"archiveEqual": @(!error && [token isEqual:restored]),
                  @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
                  @"value": token,
                  @"base64": [token base64EncodedStringWithOptions:0] };
    }
    if ([method isEqual:@"cloud.get"]) {
        id result = PearKVObject(key);
        return result ? @{ @"value": result } : @{};
    }
    if ([method isEqual:@"cloud.set"]) return @{ @"success": @(PearKVSet(key, value)) };
    if ([method isEqual:@"cloud.mutable"]) {
        NSMutableDictionary *mutableValue = [value mutableCopy];
        BOOL saved = PearKVSet(key, mutableValue);
        mutableValue[@"text"] = @"unconfirmed caller mutation";
        NSDictionary *cache = Execute(@{ @"method": @"cloud.cache" });
        return @{ @"success": @(saved), @"value": cache[@"value"][key] ?: @{} };
    }
    Class cls = NSClassFromString(@"NSUbiquitousKeyValueStore");
    if ([method isEqual:@"cloud.all"]) {
        SEL selector = @selector(dictionaryRepresentation);
        IMP imp = method_getImplementation(class_getInstanceMethod(cls, selector));
        return @{ @"value": ((NSDictionary *(*)(id, SEL))imp)(nil, selector) };
    }
    if ([method isEqual:@"cloud.sync"]) {
        SEL selector = @selector(synchronize);
        IMP imp = method_getImplementation(class_getInstanceMethod(cls, selector));
        return @{ @"success": @(((BOOL (*)(id, SEL))imp)(nil, selector)) };
    }
    abort();
}

int main(void) {
    @autoreleasepool {
        // Do not let Python's inherited SIGPIPE disposition hide a client bug.
        signal(SIGPIPE, SIG_DFL);
        struct sigaction action = {};
        action.sa_handler = Interrupted;
        sigemptyset(&action.sa_mask);
        sigaction(SIGALRM, &action, NULL);
        PearInstallKeyValueStore();
        uint32_t header;
        while (fread(&header, 1, sizeof(header), stdin) == sizeof(header)) {
            @autoreleasepool {
                NSUInteger size = ntohl(header);
                if (size == 0 || size > 4 * 1024 * 1024) return 2;
                NSMutableData *data = [NSMutableData dataWithLength:size];
                if (fread(data.mutableBytes, 1, size, stdin) != size) return 3;
                NSDictionary *command = [NSPropertyListSerialization propertyListWithData:data
                    options:NSPropertyListImmutable format:NULL error:NULL];
                struct itimerval timer = {};
                if ([command[@"interrupt"] boolValue]) {
                    timer.it_interval.tv_usec = timer.it_value.tv_usec = 1000;
                    setitimer(ITIMER_REAL, &timer, NULL);
                }
                __block NSDictionary *result;
                void (^work)(void) = ^{ @autoreleasepool {
                    uint64_t start = PearHostNow();
                    result = Execute(command);
                    if ([command[@"measure"] boolValue]) {
                        NSMutableDictionary *measured = [result mutableCopy];
                        measured[@"elapsed_ms"] = @((PearHostNow() - start) / (double)NSEC_PER_MSEC);
                        measured[@"main_thread"] = @([NSThread isMainThread]);
                        result = measured;
                    }
                } };
                if ([command[@"worker"] boolValue]) {
                    // dispatch_sync may run inline on the main thread.
                    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        work();
                        dispatch_semaphore_signal(finished);
                    });
                    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
                } else work();
                timer = {};
                setitimer(ITIMER_REAL, &timer, NULL);
                NSData *reply = [NSPropertyListSerialization dataWithPropertyList:result
                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
                if (!reply) return 4;
                header = htonl((uint32_t)reply.length);
                fwrite(&header, 1, sizeof(header), stdout);
                fwrite(reply.bytes, 1, reply.length, stdout);
                fflush(stdout);
            }
        }
    }
    return 0;
}
'''


def frame(value, fmt=plistlib.FMT_BINARY):
    payload = plistlib.dumps(value, fmt=fmt)
    return struct.pack("!I", len(payload)) + payload


def receive(fd, size, timeout=3):
    deadline = time.monotonic() + timeout
    chunks = []
    while size:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise AssertionError("runtime harness response timed out")
        chunk = os.read(fd, size)
        if not chunk:
            raise AssertionError("runtime harness exited or crashed (possibly SIGPIPE)")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


class Client:
    def __init__(self, executable, home, path=None, token: Optional[str] = TOKEN):
        self.home = home
        self.store = home / "Library/Cloud/key-values.plist"
        self.store.parent.mkdir(parents=True)
        self.sentinel = plistlib.dumps({"legacy-only": "disk", "resurrect": "old-disk",
                                       "confirmed": "old-disk"}, fmt=plistlib.FMT_BINARY)
        self.store.write_bytes(self.sentinel)
        env = clean_environment(home)
        if path is not None:
            env["PEAR_HOST_SOCKET"] = str(path)
        if token is not None:
            env["PEAR_HOST_TOKEN"] = token
        self.process = subprocess.Popen([str(executable)], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)

    def request(self, method, **fields):
        assert self.process.stdin is not None and self.process.stdout is not None
        data = frame(dict(method=method, **fields))
        while data:
            count = os.write(self.process.stdin.fileno(), data)
            data = data[count:]
        size = struct.unpack("!I", receive(self.process.stdout.fileno(), 4))[0]
        assert 0 < size <= 4 * MAX_FRAME
        return plistlib.loads(receive(self.process.stdout.fileno(), size))

    def untouched(self):
        assert self.store.read_bytes() == self.sentinel, "host-mode client modified the local plist"

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        assert self.process.stdin is not None
        assert self.process.stdout is not None and self.process.stderr is not None
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError("runtime harness did not exit")
        stderr = self.process.stderr.read().decode(errors="replace")
        self.process.stdout.close()
        self.process.stderr.close()
        if kind is None:
            assert code == 0, "runtime harness failed (%d): %s" % (code, stderr)


def clean_environment(home):
    env = os.environ.copy()
    for name in ("PEAR_HOST_SOCKET", "PEAR_HOST_TOKEN", "PEAR_LOG_FILE", "DYLD_INSERT_LIBRARIES"):
        env.pop(name, None)
    env.update(HOME=str(home), PEAR_HOME_DIR=str(home), PEAR_NO_CLOUD_SHIM="1")
    return env


class Raw:
    def __init__(self, data):
        self.data = data


class FakeHost:
    """Adversarial local peer, NOT a substitute for the optional Swift CLI test."""
    def __init__(self, path, behavior=None, values=None, fragment=0, delay: float = 0,
                 close_after_reply=False, reset_after_prefix=False, no_read=False):
        self.path = path
        self.behavior = behavior
        self.values = dict(values or {})
        self.fragment, self.delay = fragment, delay
        self.close_after_reply = close_after_reply
        self.reset_after_prefix, self.no_read = reset_after_prefix, no_read
        self.records, self.errors, self.peers, self.workers = [], [], [], []
        self.connections = self.partial = 0
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen(8)
        self.listener.settimeout(0.05)
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                peer, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self.lock:
                self.connections += 1
                self.peers.append(peer)
            worker = threading.Thread(target=self.serve, args=(peer,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def exact(self, peer, size):
        result = bytearray()
        while len(result) < size:
            chunk = peer.recv(min(size - len(result), 4096))
            if not chunk:
                raise EOFError()
            result.extend(chunk)
        return bytes(result)

    def response(self, request):
        if type(request.get("version")) is not int or request["version"] != 1 or request.get("token") != TOKEN:
            return {"ok": False, "error": "unauthorized request"}
        op = request.get("op")
        if op == "ping":
            return {"ok": True, "service": "pear-host", "bundle": BUNDLE, "version": 1}
        key = request.get("key")
        if op == "kv.get":
            return dict(ok=True, found=True, value=self.values[key]) if key in self.values else dict(ok=True, found=False)
        if op == "kv.set":
            candidate = dict(self.values)
            if "value" in request:
                candidate[key] = request["value"]
            else:
                candidate.pop(key, None)
            if len(plistlib.dumps(candidate, fmt=plistlib.FMT_BINARY)) > 524_288:
                return {"ok": False, "error": "store exceeds 512 KiB"}
            self.values = candidate
            return {"ok": True}
        if op == "kv.all":
            return {"ok": True, "value": self.values}
        return {"ok": False, "error": "unknown operation"}

    def serve(self, peer):
        try:
            peer.settimeout(2)
            if self.no_read:
                self.stopped.wait(2)
                return
            messages = 0
            while not self.stopped.is_set():
                if messages and self.reset_after_prefix:
                    self.exact(peer, 5)  # Some of a mutation has arrived; no ACK.
                    self.partial += 1
                    peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    return
                size = struct.unpack("!I", self.exact(peer, 4))[0]
                assert 0 < size <= MAX_FRAME, "client sent an oversized frame"
                payload = self.exact(peer, size)
                assert payload.startswith(b"bplist00"), "client did not use binary plist"
                request = plistlib.loads(payload)
                assert isinstance(request, dict)
                with self.lock:
                    self.records.append(request)
                    index = len(self.records)
                    result = self.behavior(self, request, index) if self.behavior else self.response(request)
                if result is None:
                    return
                reply = result.data if isinstance(result, Raw) else frame(result)
                step = self.fragment or len(reply)
                for offset in range(0, len(reply), step):
                    peer.sendall(reply[offset:offset + step])
                    if self.delay:
                        self.stopped.wait(self.delay)
                messages += 1
                if isinstance(result, Raw) or self.close_after_reply:
                    return
        except (EOFError, OSError):
            pass  # Client reset/deadline is expected in adversarial cases.
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            peer.close()

    def stop(self):
        if self.stopped.is_set():
            return
        self.stopped.set()
        self.listener.close()
        self.thread.join(timeout=1)
        for peer in self.peers:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for worker in self.workers:
            worker.join(timeout=1)
        self.path.unlink(missing_ok=True)
        assert not self.errors, self.errors

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.stop()


def ping(client, **fields):
    return client.request("call", request={"op": "ping"}, **fields)


def exercise_kv(client):
    assert client.request("configured") == {"configured": True}
    reply = client.request("call", request={"op": "ping", "token": "must-be-overwritten", "version": 999})
    assert reply["success"] and reply["response"]["ok"]
    flags = client.request("flags")
    assert flags == {"nosigpipe": 1, "uid": os.getuid(), "nonblocking": True, "cloexec": True}
    typed = {"text": "hello 🧪", "boolean": True, "integer": 9_007_199_254_740_993,
             "real": 1.25, "data": bytes(range(256)), "date": datetime.datetime(2025, 1, 2, 3, 4, 5),
             "array": [False, {"nested": [b"\0\xff", 42]}], "dictionary": {"empty": []}}
    assert client.request("set", key="typed", value=typed)["success"]
    result = client.request("get", key="typed")
    assert result == {"success": True, "value": typed}
    assert type(result["value"]["boolean"]) is bool and type(result["value"]["integer"]) is int
    assert client.request("get", key="missing") == {"success": True}
    assert client.request("set", key="typed")["success"]
    assert client.request("get", key="typed") == {"success": True}
    for key in ("", "🧪" * 300):
        assert client.request("get", key=key) == {"success": False}
    assert not client.request("set", key="invalid", value=None)["success"]  # NSNull is NOT deletion.
    assert not client.request("set", key="oversized", value=b"x" * MAX_FRAME)["success"]
    assert ping(client)["success"]  # Invalid outgoing values did not poison the stream.
    rejected = client.request("call", request={"op": "unknown"})
    assert rejected["success"] and rejected["response"]["ok"] is False
    assert isinstance(rejected["response"]["error"], str)
    assert client.request("cloud.get", key="legacy-only") == {}
    assert client.request("cloud.mutable", key="confirmed", value=typed) == {"success": True, "value": typed}
    assert client.request("cloud.set", key="resurrect", value="host-value")["success"]
    assert client.request("cloud.get", key="resurrect")["value"] == "host-value"
    # Delete outside the Cloud cache; confirmed missing MUST evict its old value.
    assert client.request("set", key="resurrect")["success"]
    assert client.request("cloud.get", key="resurrect") == {}
    assert "resurrect" not in client.request("cloud.all")["value"]
    assert client.request("cloud.sync")["success"]
    # Persistence rejection must not report success, even if reads still work.
    assert not client.request("cloud.set", key="confirmed", value=b"x" * 600_000, worker=True)["success"]
    assert client.request("cloud.get", key="confirmed")["value"] == typed
    assert not client.request("cloud.sync")["success"]
    assert client.request("cloud.set", key="confirmed", value=typed)["success"]
    assert client.request("cloud.sync")["success"]
    client.untouched()
    return typed


def outage(client, typed):
    assert client.request("get", key="confirmed") == {"success": False}
    assert client.request("cloud.get", key="confirmed")["value"] == typed
    assert client.request("cloud.get", key="resurrect") == {}
    assert client.request("cloud.get", key="legacy-only") == {}
    assert not client.request("cloud.set", key="offline", value="must-not-appear")["success"]
    snapshot = client.request("cloud.all")["value"]
    assert snapshot == {"confirmed": typed}
    assert not client.request("cloud.sync")["success"]
    client.untouched()


def recovery(client):
    time.sleep(0.28)  # Respect the production reconnect cooldown.
    assert ping(client)["success"]
    assert not client.request("cloud.sync")["success"]  # Healthy reads don't ACK a failed write.
    assert client.request("cloud.set", key="offline", value="explicit-retry")["success"]
    assert client.request("cloud.sync")["success"]
    client.untouched()


def run_identity_tests(executable, root):
    previous = None
    for index, host_path in enumerate((None, root / "unavailable-identity-host.sock")):
        # A new process and a different data home must keep the same local
        # identity. No host/iCloud service is needed to encode this opaque token.
        with Client(executable, root / ("identity-%d" % index), host_path, token=None) as client:
            result = client.request("cloud.identity")
            assert result.get("isData"), "ubiquityIdentityToken must support the SDK's NSData/Base64 path"
            expected = ("pearsilicon-local-" + result["bundle"]).encode("utf-8")
            assert result["value"] == expected
            assert result["base64"] == base64.b64encode(expected).decode("ascii")
            assert not result["mutable"]
            assert result["stable"] and result["copyEqual"] and result["archiveEqual"]
            assert client.request("cloud.identity") == result
            if previous is not None:
                assert result == previous, "local token changed across processes/storage roots"
            previous = result
            client.untouched()
    print("PASS ubiquity token: immutable NSData, Base64, secure archive/copy, stable across processes/roots; local KV untouched", flush=True)


def run_fake_tests(executable, root):
    path = root / "host.sock"
    with FakeHost(path) as host, Client(executable, root / "fake-home", path) as client:
        typed = exercise_kv(client)
        # Configuration/token are captured for the process, not reselected on an outage.
        assert client.request("environment") == {"configured": True}
        assert ping(client)["success"]
        host.stop()
        outage(client, typed)
        with FakeHost(path, values=host.values):
            recovery(client)
    print("PASS typed IPC, missing/deletion, immutable cache, exclusive writer, outage/recovery", flush=True)

    with Client(executable, root / "legacy-home", token=None) as client:
        assert client.request("configured") == {"configured": False}
        assert client.request("cloud.get", key="legacy-only") == {"value": "disk"}
        assert client.request("cloud.set", key="legacy-write", value="saved")["success"]
        assert client.request("cloud.sync")["success"]
        assert plistlib.loads(client.store.read_bytes())["legacy-write"] == "saved"
        assert client.request("environment", PEAR_HOST_SOCKET=str(path), PEAR_HOST_TOKEN=TOKEN) == {"configured": False}
        assert not ping(client)["success"]
    for index, (configured_path, token) in enumerate((("", TOKEN), ("relative", TOKEN),
                                                     (str(root / "absent.sock"), TOKEN),
                                                     (str(path), None), (str(path), ""))):
        with Client(executable, root / ("invalid-%d" % index), configured_path, token) as client:
            assert client.request("configured") == {"configured": True}
            assert not ping(client)["success"]
            assert client.request("get", key="legacy-only") == {"success": False}
            assert client.request("cloud.get", key="legacy-only") == {}
            assert not client.request("cloud.set", key="offline", value="no")["success"]
            assert not client.request("cloud.sync")["success"]
            client.untouched()
    with FakeHost(path), Client(executable, root / "bad-token", path, "incorrect") as client:
        result = ping(client)
        assert result["success"] and result["response"]["ok"] is False
        assert client.request("cloud.get", key="legacy-only") == {}
        assert not client.request("cloud.set", key="offline", value="no")["success"]
        assert not client.request("cloud.sync")["success"]
        client.untouched()
    print("PASS legacy mode, fixed configuration, missing/invalid credentials fail closed", flush=True)

    bad_replies = [
        ("zero", "ping", Raw(struct.pack("!I", 0))),
        ("oversized", "ping", Raw(struct.pack("!I", MAX_FRAME + 1))),
        ("short-header", "ping", Raw(b"\0\0")),
        ("short-body", "ping", Raw(struct.pack("!I", 100) + b"bplist00")),
        ("garbage", "ping", Raw(struct.pack("!I", 4) + b"nope")),
        ("xml", "ping", Raw(frame({"ok": True}, plistlib.FMT_XML))),
        ("array", "ping", Raw(frame([True]))),
        ("missing-ok", "ping", {}),
        ("numeric-ok", "ping", {"ok": 1}),
        ("invalid-error", "ping", {"ok": False, "error": 3}),
        ("numeric-found", "kv.get", {"ok": True, "found": 0}),
        ("missing-value", "kv.get", {"ok": True, "found": True}),
        ("unexpected-value", "kv.get", {"ok": True, "found": False, "value": "stale"}),
        ("null-value", "kv.get", {"ok": True, "found": True, "value": None}),
        ("invalid-snapshot", "kv.all", {"ok": True, "value": []}),
        ("wrong-service", "ping", {"ok": True, "service": "wrong", "bundle": BUNDLE, "version": 1}),
        ("wrong-bundle-type", "ping", {"ok": True, "service": "pear-host", "bundle": 2, "version": 1}),
        ("boolean-version", "ping", {"ok": True, "service": "pear-host", "bundle": BUNDLE, "version": True}),
        ("float-version", "ping", {"ok": True, "service": "pear-host", "bundle": BUNDLE, "version": 1.0}),
    ]
    for name, operation, bad in bad_replies:
        def malformed(host, request, index):
            return bad if index == 1 else host.response(request)
        with FakeHost(path, behavior=malformed) as host, Client(executable, root / name, path) as client:
            assert not client.request("call", request={"op": operation, "key": "key"})["success"], name
            assert not ping(client)["success"]  # Cooldown: no reconnect spin.
            assert len(host.records) == 1
            time.sleep(0.28)
            assert ping(client)["success"], "did not reset malformed connection: " + name
            assert host.connections == 2
    print("PASS malformed/oversized replies, strict response types, connection reset/cooldown", flush=True)

    with FakeHost(path, fragment=7, delay=0.001), Client(executable, root / "partial", path) as client:
        assert ping(client, interrupt=True)["success"]  # EINTR + partial header/body.
        start = time.monotonic()
        assert not client.request("lockwait")["success"]
        assert 0.07 <= time.monotonic() - start < 0.35
    for worker in (False, True):
        with FakeHost(path, fragment=1, delay=0.04) as host, Client(executable, root / ("slow-%s" % worker), path) as client:
            start = time.monotonic()
            assert not ping(client, worker=worker, interrupt=True)["success"]
            elapsed = time.monotonic() - start
            assert (0.42 if worker else 0.07) <= elapsed < (0.8 if worker else 0.35), elapsed
            assert host.connections == 1
    with FakeHost(path, no_read=True), Client(executable, root / "backpressure", path) as client:
        start = time.monotonic()
        assert not client.request("set", key="big", value=b"x" * 900_000)["success"]
        assert time.monotonic() - start < 0.4
    with FakeHost(path, close_after_reply=True) as host, Client(executable, root / "stale", path) as client:
        for _ in range(3):
            assert ping(client)["success"]
            time.sleep(0.03)
        assert host.connections == 3
    print("PASS partial I/O/EINTR, total read/write/lock deadlines, idle connection recovery", flush=True)

    def lost_ack(host, request, index):
        result = host.response(request)
        return None if request.get("op") == "kv.set" else result
    with FakeHost(path, behavior=lost_ack) as host, Client(executable, root / "lost-ack", path) as client:
        assert ping(client)["success"]  # Exercise a previously live persistent connection.
        assert not client.request("set", key="ambiguous", value="once")["success"]
        time.sleep(0.28)
        assert host.values["ambiguous"] == "once"  # Committed, but ACK lost.
        assert len(host.records) == 2 and host.connections == 1, "unsafe mutation replay"
        assert ping(client)["success"]
        assert len([r for r in host.records if r["op"] == "kv.set"]) == 1
    with FakeHost(path, reset_after_prefix=True) as host, Client(executable, root / "broken-peer", path) as client:
        assert ping(client)["success"]
        assert not client.request("set", key="partial", value=b"x" * 900_000)["success"]
        time.sleep(0.28)
        assert host.partial == 1 and host.connections == 1, "unsafe partial-write replay"
        assert ping(client)["success"]  # Process survived the broken peer without SIGPIPE.
    print("PASS lost ACK/partial mutation are never replayed; broken peer cannot raise SIGPIPE", flush=True)


def timed_cloud(client, method, worker=False, **fields):
    result = client.request(method, worker=worker, measure=True, **fields)
    elapsed = result.pop("elapsed_ms")
    assert result.pop("main_thread") is not worker
    # Scheduler tolerance, not another operation budget. The success/cache
    # assertions below independently reject incorrectly renewed transport time.
    lower, upper = (450, 560) if worker else (75, 140)
    assert lower <= elapsed < upper, (method, worker, elapsed)
    return result


def run_cloud_deadline_tests(executable, root):
    path = root / "cloud-gate.sock"
    methods = ("cloud.get", "cloud.set", "cloud.all", "cloud.sync")
    empty = {"cloud.get": {}, "cloud.set": {"success": False},
             "cloud.all": {"value": {}}, "cloud.sync": {"success": False}}
    cached = dict(empty, **{"cloud.get": {"value": "confirmed"},
                           "cloud.all": {"value": {"confirmed": "confirmed"}}})
    for worker in (False, True):
        for method in methods:
            name = "%s-%s" % (method, worker)
            with FakeHost(path) as host, Client(executable, root / ("gate-" + name), path) as client:
                assert client.request("cloud.set", key="confirmed", value="confirmed")["success"]
                records = len(host.records)
                # A different worker owns the actual production operation gate.
                client.request("gate.hold", gate="cloud", milliseconds=700 if worker else 300)
                result = timed_cloud(client, method, worker, key="confirmed", value="never-confirmed")
                assert result == empty[method], (name, result)
                assert len(host.records) == records, "timed-out gate still issued IPC"
                client.request("gate.wait")
                state = client.request("cloud.cache")
                assert state["value"] == {"confirmed": "confirmed"}
                assert state["unconfirmed"] == (1 if method == "cloud.set" else 0)
                assert client.request("cloud.sync")["success"] is (method != "cloud.set")
                if method == "cloud.set":
                    # Reading the failed key cannot manufacture a write ACK.
                    assert client.request("cloud.get", key="confirmed")["value"] == "confirmed"
                    assert not client.request("cloud.sync")["success"]
                    assert client.request("cloud.set", key="confirmed", value="explicit-retry")["success"]
                    assert client.request("cloud.sync")["success"]
                client.untouched()
    print("PASS Cloud get/set/all/sync: contended gate bounded by 100 ms main / 500 ms worker; no unsafe cache/success", flush=True)

    for worker in (False, True):
        for method in methods:
            name = "%s-%s" % (method, worker)
            def delayed(host, request, index):
                if index > 1:
                    host.stopped.wait(0.30 if worker else 0.075)
                return host.response(request)
            with FakeHost(path, behavior=delayed) as host, Client(executable, root / ("shared-" + name), path) as client:
                assert client.request("cloud.set", key="confirmed", value="confirmed")["success"]
                # If the gate gave transport a fresh budget, the reply would
                # succeed at ~135/600 ms. One deadline must reject that reply.
                host.values = {"confirmed": "late-host-value", "new-key": "late"}
                client.request("gate.hold", gate="cloud", milliseconds=300 if worker else 60)
                result = timed_cloud(client, method, worker, key="confirmed", value="no-ack")
                assert result == cached[method], (name, result)
                assert len(host.records) == 2, "test did not reach the socket after gate wait"
                client.request("gate.wait")
                state = client.request("cloud.cache")
                assert state["value"] == {"confirmed": "confirmed"}
                assert state["unconfirmed"] == (1 if method == "cloud.set" else 0)
                client.untouched()
    print("PASS Cloud gate wait + socket I/O share one entry deadline, never two budgets", flush=True)

    for worker in (False, True):
        with FakeHost(path) as host, Client(executable, root / ("both-locks-%s" % worker), path) as client:
            assert client.request("cloud.set", key="confirmed", value="confirmed")["success"]
            client.request("gate.hold", gate="cloud", milliseconds=300 if worker else 60)
            client.request("gate.hold", gate="transport", milliseconds=700 if worker else 220)
            result = timed_cloud(client, "cloud.set", worker, key="confirmed", value="never-sent")
            assert result == {"success": False}
            assert len(host.records) == 1, "expired client-lock wait sent a mutation"
            client.request("gate.wait")
            assert client.request("cloud.cache")["value"] == {"confirmed": "confirmed"}
            assert not client.request("cloud.sync")["success"]
            assert client.request("cloud.set", key="confirmed", value="explicit-retry")["success"]
            assert client.request("cloud.sync")["success"]
            client.untouched()
    print("PASS Cloud gate and gHostLock consume the same deadline", flush=True)

    for method in ("cloud.sync", "cloud.set"):
        entered, release = threading.Event(), threading.Event()
        def in_flight(host, request, index):
            if index == 2:
                entered.set()
                assert release.wait(1), "test did not release the in-flight ACK"
            return host.response(request)
        with FakeHost(path, behavior=in_flight), Client(executable, root / ("late-rejection-" + method), path) as client:
            assert client.request("cloud.set", key="confirmed", value="confirmed")["success"]
            client.request("async.start", command={"method": method, "key": "confirmed", "value": "earlier-write"})
            assert entered.wait(1), "worker did not enter Cloud IPC"
            try:
                assert timed_cloud(client, "cloud.set", key="confirmed", value="rejected-write") == {"success": False}
            finally:
                release.set()
            # A healthy snapshot or an earlier set ACK cannot acknowledge the
            # setter rejected by the occupied gate during that same IPC.
            assert client.request("async.wait")["success"] is (method == "cloud.set")
            assert not client.request("cloud.sync")["success"]
            assert client.request("cloud.set", key="confirmed", value="explicit-retry")["success"]
            assert client.request("cloud.sync")["success"]
            client.untouched()
    print("PASS concurrent gate-rejected writes remain unconfirmed across earlier ACKs/healthy sync", flush=True)


class CLIHost:
    def __init__(self, executable, root):
        self.executable, self.root = executable, root
        self.path = root / "ipc/host.sock"
        self.data = root / "data"
        self.process = None

    def start(self):
        self.path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.data.mkdir(parents=True, exist_ok=True)
        env = clean_environment(self.root)
        env["PEAR_HOST_TOKEN"] = TOKEN
        self.log = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(self.executable), "host-service", "--socket", str(self.path),
                                         "--bundle", BUNDLE, "--data", str(self.data)],
                                        env=env, stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 5
        while not self.path.exists():
            if self.process.poll() is not None or time.monotonic() >= deadline:
                self.log.seek(0)
                detail = self.log.read().decode(errors="replace")
                self.close()
                raise AssertionError("CLI host failed to start: " + detail)
            time.sleep(0.01)
        time.sleep(0.03)

    def stopped(self):
        assert self.process is not None
        assert self.process.wait(timeout=3) == 0
        self.log.close()
        self.process = None

    def close(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.log.close()
            self.process = None


def run_cli_tests(executable, cli, root):
    host = CLIHost(cli, root / "cli")
    try:
        host.start()
        with Client(executable, root / "cli-home", host.path) as client:
            typed = exercise_kv(client)
            # Verify the real host persisted plist-native values, not JSON conversions.
            store = host.data / "Library/Cloud/key-values.plist"
            assert plistlib.loads(store.read_bytes()) == {"confirmed": typed}
            assert client.request("call", request={"op": "session.stop"})["response"]["ok"]
            host.stopped()
            outage(client, typed)
            host.start()
            recovery(client)
            assert client.request("get", key="confirmed")["value"] == typed
            assert client.request("call", request={"op": "session.stop"})["response"]["ok"]
            host.stopped()
        print("PASS supplied CLI: authenticated typed IPC, persistence, shutdown/outage/restart", flush=True)
    finally:
        host.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", nargs="?", type=Path, help="CLI executable with host-service support")
    args = parser.parse_args()
    if args.host:
        args.host = args.host.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="pear-rt-", dir="/tmp") as directory:
        root = Path(directory)
        stub = root / "include/UIKit"
        stub.mkdir(parents=True)
        (stub / "UIKit.h").write_text("#import <CoreGraphics/CoreGraphics.h>\n")
        source = root / "client.mm"
        source.write_text(HARNESS)
        executable = root / "runtime-client"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks",
                        "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-local-typedef",
                        "-I" + str(root / "include"), "-I" + str(ROOT / "runtime/include"),
                        "-I" + str(ROOT / "runtime"), str(source), "-framework", "Foundation",
                        "-framework", "CoreGraphics", "-o", str(executable)], check=True, timeout=60)
        run_identity_tests(executable, root)
        run_cloud_deadline_tests(executable, root)
        run_fake_tests(executable, root)
        if args.host:
            run_cli_tests(executable, args.host, root)
        else:
            print("SKIP real CLI integration (supply its executable as the positional argument)", flush=True)
    print("All requested runtime-client smoke tests passed.", flush=True)


if __name__ == "__main__":
    main()
