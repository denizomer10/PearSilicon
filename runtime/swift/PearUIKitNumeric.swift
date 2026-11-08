// PearUIKitNumeric.swift
//
// The UIKit Swift overlay is not shipped by the Mac Catalyst host runtime.
// Apps compiled against it can reference `_UIKitNumericRawRepresentable` for
// values such as `UIWindow.Level`, `UILayoutPriority`, and `UIFont.Weight`.
//
// This file is compiled as the `UIKit` module (via `-module-name UIKit` and a
// module alias for the system headers) so the compiler emits the same mangled
// protocol, witness table, conformance descriptor, and operator symbols the
// original overlay exports. Hand-written assembly and a zero-filled descriptor
// are not ABI-correct and caused RockstarMobile's timer block to crash.
import AppleUIKit

public protocol _UIKitNumericRawRepresentable: Comparable, RawRepresentable
where RawValue: Comparable & Numeric {
}

extension _UIKitNumericRawRepresentable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func + (lhs: Self, rhs: Self.RawValue) -> Self {
        Self(rawValue: lhs.rawValue + rhs)!
    }

    public static func + (lhs: Self.RawValue, rhs: Self) -> Self {
        Self(rawValue: lhs + rhs.rawValue)!
    }

    public static func - (lhs: Self, rhs: Self.RawValue) -> Self {
        Self(rawValue: lhs.rawValue - rhs)!
    }

    public static func - (lhs: Self, rhs: Self) -> Self.RawValue {
        lhs.rawValue - rhs.rawValue
    }

    public static func += (lhs: inout Self, rhs: Self.RawValue) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout Self, rhs: Self.RawValue) {
        lhs = lhs - rhs
    }
}

extension UIWindow.Level: _UIKitNumericRawRepresentable {
}
