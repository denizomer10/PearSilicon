// PearSwiftUIKitSupport.c
//
// Data symbols needed by Swift overlays that were compiled against the UIKit
// module. The force-load marker is intentionally empty; the protocol
// conformance, witness table, and generic operators are emitted by the Swift
// compiler from PearUIKitNumeric.swift.
//
// This file contains no vendor code; the symbol names are interface facts.

__asm__(
    ".globl __swift_FORCE_LOAD_$_swiftUIKit\n"
    "__swift_FORCE_LOAD_$_swiftUIKit:\n"
    ".byte 0\n"
);
