// cxxcompat.cpp
//
// A small re-export shim for the C++ runtime. Some Catalyst binaries contain a
// weak placeholder for std::__1::piecewise_construct and expect the C++ runtime
// to provide the real object. The host runtime does not export that data
// symbol, so the placeholder is never coalesced and Swift metadata resolution
// fails. This library re-exports the system C++ runtime and supplies the empty
// tag object locally.
//
// The symbol is an empty struct; a one-byte definition is sufficient.

__asm__(
    ".globl __ZNSt3__119piecewise_constructE\n"
    "__ZNSt3__119piecewise_constructE:\n"
    ".byte 0\n"
);
