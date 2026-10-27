// PearSwiftUIKitSupport.c
//
// Data symbols needed by Swift overlays that were compiled against the UIKit
// module. The force-load marker is intentionally empty. The protocol
// conformance descriptor is a local placeholder: it satisfies link-time
// binding for code paths that are not exercised by the host, while the actual
// indexed/action/menu conveniences are implemented in PearSwiftUIKit.swift.
//
// This file contains no vendor code; the symbol names are interface facts.

__asm__(
    ".globl __swift_FORCE_LOAD_$_swiftUIKit\n"
    "__swift_FORCE_LOAD_$_swiftUIKit:\n"
    ".byte 0\n"
    ".globl _$sSo13UIWindowLevela5UIKit01_C23NumericRawRepresentableACMc\n"
    "_$sSo13UIWindowLevela5UIKit01_C23NumericRawRepresentableACMc:\n"
    ".space 128, 0\n"
);
