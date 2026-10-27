// PearSwiftUIKit.swift
//
// A tiny compatibility overlay for the handful of Swift-imported UIKit
// conveniences that a Mac Catalyst process can reference but the host runtime
// does not ship. These are thin bridges over public Foundation/UIKit
// initializers and values; no vendor source or binary is copied.
//
// The dependency name in the app is fixed (`libswiftUIKit.dylib`), so the
// product keeps that install name. The implementations live here and are
// compiled from source with the same public APIs an app would use.
import Foundation
import UIKit

@_silgen_name("$s10Foundation9IndexPathV5UIKitE3rowSivg")
public func pearIndexPathRow(_ indexPath: IndexPath) -> Int {
    indexPath[1]
}

@_silgen_name("$s10Foundation9IndexPathV5UIKitE4itemSivg")
public func pearIndexPathItem(_ indexPath: IndexPath) -> Int {
    indexPath[1]
}

@_silgen_name("$s10Foundation9IndexPathV5UIKitE7sectionSivg")
public func pearIndexPathSection(_ indexPath: IndexPath) -> Int {
    indexPath[0]
}

@_silgen_name("$s10Foundation9IndexPathV5UIKitE4item7sectionACSi_SitcfC")
public func pearIndexPathMake(item: Int, section: Int) -> IndexPath {
    IndexPath(indexes: [section, item])
}

@_silgen_name("$s10Foundation9IndexPathV5UIKitE3row7sectionACSi_SitcfC")
public func pearIndexPathMake(row: Int, section: Int) -> IndexPath {
    IndexPath(indexes: [section, row])
}

@_silgen_name("$sSo15UITextDirectiona5UIKitE6layoutyABSo0a6LayoutB0VFZ")
public func pearTextDirectionLayout(_ direction: UITextLayoutDirection) -> UITextDirection {
    UITextDirection(rawValue: direction.rawValue)
}

@_silgen_name("$sSo13UIFocusSystemC5UIKitE05focusB03forABSgSo0A11Environment_p_tFZ")
public func pearFocusSystem(for environment: any UIFocusEnvironment) -> UIFocusSystem? {
    // The host does not expose the private focus-system factory. Returning nil
    // is the documented "no focus system" answer and lets callers fall back.
    _ = environment
    return nil
}

@_silgen_name("$sSo21UIContentSizeCategorya5UIKitE015isAccessibilityC0Sbvg")
public func pearIsAccessibilityCategory(_ category: UIContentSizeCategory) -> Bool {
    category.rawValue.hasPrefix("UICTContentSizeCategoryAccessibility")
}

extension UIBarButtonItem {
    @_silgen_name("$sSo15UIBarButtonItemC5UIKitE5title5image13primaryAction4menuABSSSg_So7UIImageCSgSo8UIActionCSgSo6UIMenuCSgtcfC")
    public convenience init(pearTitle title: String?, image: UIImage?,
                            primaryAction: UIAction?, menu: UIMenu?) {
        self.init(title: title, style: .plain, target: nil, action: nil)
        self.image = image
        self.primaryAction = primaryAction
        self.menu = menu
    }
}
