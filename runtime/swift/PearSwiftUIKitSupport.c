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
    // UIKit's Swift overlay defines this numeric raw-representable `+`
    // operator generically. Rockstar's RockstarMobile framework calls it for
    // UIWindow.Level while presenting its startup banner; without the symbol
    // the lazy pointer stays null and the game crashes on the first timer.
    // The generic Swift ABI passes the result buffer in x8, the lhs in x0,
    // the rhs in x1, metadata in x2, and the witness table in x3. A
    // UIWindow.Level is a single CGFloat, so the add can be done directly.
    ".globl _$s5UIKit01_A23NumericRawRepresentablePAAE1poiyxx_0C5ValueQztFZ\n"
    "_$s5UIKit01_A23NumericRawRepresentablePAAE1poiyxx_0C5ValueQztFZ:\n"
    "ldr d0, [x0]\n"
    "ldr d1, [x1]\n"
    "fadd d0, d0, d1\n"
    "str d0, [x8]\n"
    "ret\n"
);
