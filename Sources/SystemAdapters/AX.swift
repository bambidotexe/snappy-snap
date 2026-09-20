import ApplicationServices
import CoreGraphics
import Foundation

/// Thin wrappers over the C Accessibility API. Every call is synchronous IPC to the target app.
public enum AX {
    public static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    public static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    public static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) }

    public static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as NSNumber?)?.boolValue
    }

    public static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value: AXValue = attribute(element, name) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &p) ? p : nil
    }

    public static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value: AXValue = attribute(element, name) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value, .cgSize, &s) ? s : nil
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ name: String, point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ name: String, size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }
}
