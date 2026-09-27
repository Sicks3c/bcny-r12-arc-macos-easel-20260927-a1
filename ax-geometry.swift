import Foundation
import AppKit
import ApplicationServices

func copied(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ name: CFString) -> String {
    return (copied(element, name) as? String) ?? ""
}

func boolAttr(_ element: AXUIElement, _ name: CFString) -> Bool? {
    return (copied(element, name) as? NSNumber)?.boolValue
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    return (copied(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func actions(_ element: AXUIElement) -> [String] {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success,
          let names = raw as? [String] else { return [] }
    return names.sorted()
}

func isSettable(_ element: AXUIElement, _ name: CFString) -> Bool {
    var result = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name, &result) == .success && result.boolValue
}

func hasSettableAttribute(_ element: AXUIElement) -> Bool {
    var raw: CFArray?
    guard AXUIElementCopyAttributeNames(element, &raw) == .success,
          let names = raw as? [String] else { return true }
    for name in names where isSettable(element, name as CFString) {
        return true
    }
    return false
}

func nodeAt(_ root: AXUIElement, _ indices: [Int]) -> AXUIElement? {
    var node = root
    for index in indices {
        let kids = children(node)
        guard index >= 0 && index < kids.count else { return nil }
        node = kids[index]
    }
    return node
}

func pointAttr(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let raw = copied(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return point
}

func sizeAttr(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let raw = copied(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return size
}

func rectAttr(_ element: AXUIElement, _ name: CFString) -> CGRect? {
    guard let raw = copied(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgRect else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
    return rect
}

func near(_ left: CGFloat, _ right: CGFloat) -> Bool {
    return abs(left - right) < 0.01
}

guard CommandLine.arguments.count == 2,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(160) }

let root = AXUIElementCreateApplication(pid_t(parsedPID))
guard let window = nodeAt(root, [0]),
      stringAttr(window, kAXRoleAttribute as CFString) == "AXWindow",
      let privacy = nodeAt(root, [0,0,14]),
      stringAttr(privacy, kAXRoleAttribute as CFString) == "AXUnknown",
      stringAttr(privacy, kAXIdentifierAttribute as CFString) == "PrivacyCheckbox",
      boolAttr(privacy, kAXEnabledAttribute as CFString) == true,
      actions(privacy).isEmpty,
      !hasSettableAttribute(privacy),
      let ownerWindow = copied(privacy, kAXWindowAttribute as CFString),
      CFGetTypeID(ownerWindow) == AXUIElementGetTypeID(),
      CFEqual(ownerWindow, window) else { exit(161) }

guard let activation = pointAttr(privacy, "AXActivationPoint" as CFString),
      let frame = rectAttr(privacy, "AXFrame" as CFString),
      let position = pointAttr(privacy, kAXPositionAttribute as CFString),
      let size = sizeAttr(privacy, kAXSizeAttribute as CFString),
      let mainVisible = NSScreen.main?.visibleFrame else { exit(162) }

guard near(frame.origin.x, position.x),
      near(frame.origin.y, position.y),
      near(frame.size.width, size.width),
      near(frame.size.height, size.height),
      frame.contains(activation) else { exit(163) }

print("path=0/0/14 role=AXUnknown identifier=PrivacyCheckbox enabled=true action_count=0 settable_count=0 owner_window_equal=true")
print("activation_x=\(activation.x) activation_y=\(activation.y)")
print("frame_x=\(frame.origin.x) frame_y=\(frame.origin.y) frame_width=\(frame.size.width) frame_height=\(frame.size.height)")
print("position_x=\(position.x) position_y=\(position.y) size_width=\(size.width) size_height=\(size.height)")
print("main_visible_x=\(mainVisible.origin.x) main_visible_y=\(mainVisible.origin.y) main_visible_width=\(mainVisible.size.width) main_visible_height=\(mainVisible.size.height)")
print("attribute_values_read=5 privacy_actions_performed=0 keyboard_events=0 screenshots=0 account_actions=0 object_actions=0 share_actions=0")
