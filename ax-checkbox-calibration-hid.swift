import Foundation
import AppKit
import ApplicationServices
import CryptoKit

struct PrivacyGeometry {
    let activation: CGPoint
    let frame: CGRect
    let position: CGPoint
    let size: CGSize
}

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

func sameGeometry(_ left: PrivacyGeometry, _ right: PrivacyGeometry) -> Bool {
    return near(left.activation.x, right.activation.x) && near(left.activation.y, right.activation.y)
        && near(left.frame.origin.x, right.frame.origin.x) && near(left.frame.origin.y, right.frame.origin.y)
        && near(left.frame.size.width, right.frame.size.width) && near(left.frame.size.height, right.frame.size.height)
        && near(left.position.x, right.position.x) && near(left.position.y, right.position.y)
        && near(left.size.width, right.size.width) && near(left.size.height, right.size.height)
}

func requireField(_ root: AXUIElement, path: [Int], identifier: String, secure: Bool) -> AXUIElement? {
    guard let field = nodeAt(root, path),
          stringAttr(field, kAXRoleAttribute as CFString) == "AXTextField",
          stringAttr(field, kAXIdentifierAttribute as CFString) == identifier,
          stringAttr(field, kAXSubroleAttribute as CFString) == (secure ? "AXSecureTextField" : ""),
          boolAttr(field, kAXEnabledAttribute as CFString) == true,
          isSettable(field, kAXFocusedAttribute as CFString),
          isSettable(field, kAXValueAttribute as CFString),
          actions(field) == ["AXConfirm", "AXShowMenu"] else { return nil }
    return field
}

func createMatches(_ root: AXUIElement, enabled: Bool) -> Bool {
    guard let create = nodeAt(root, [0,0,15]) else { return false }
    return stringAttr(create, kAXRoleAttribute as CFString) == "AXButton"
        && stringAttr(create, kAXDescriptionAttribute as CFString) == "Create an account"
        && boolAttr(create, kAXEnabledAttribute as CFString) == enabled
        && actions(create) == ["AXPress"]
}

func resolvePrivacy(_ root: AXUIElement, displayBounds: CGRect) -> PrivacyGeometry? {
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
          CFEqual(ownerWindow, window),
          let activation = pointAttr(privacy, "AXActivationPoint" as CFString),
          let frame = rectAttr(privacy, "AXFrame" as CFString),
          let position = pointAttr(privacy, kAXPositionAttribute as CFString),
          let size = sizeAttr(privacy, kAXSizeAttribute as CFString),
          near(frame.origin.x, position.x), near(frame.origin.y, position.y),
          near(frame.size.width, size.width), near(frame.size.height, size.height),
          frame.contains(activation), displayBounds.contains(activation) else { return nil }
    return PrivacyGeometry(activation: activation, frame: frame, position: position, size: size)
}

func digest(_ text: String) -> SHA256.Digest {
    return SHA256.hash(data: Data(text.utf8))
}

func typeUnicode(_ text: String, to pid: pid_t) -> Bool {
    for unit in text.utf16 {
        var scalar = unit
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &scalar)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &scalar)
        down.postToPid(pid)
        up.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.025)
    }
    return true
}

func postHIDClick(_ point: CGPoint) -> Bool {
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else { return false }
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 1.0)
    return true
}

func runningActive(_ pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    return !app.isTerminated && app.isActive
}

func workspaceFrontmost(_ pid: pid_t) -> Bool {
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

func axFrontmost(_ pid: pid_t) -> Bool {
    let root = AXUIElementCreateApplication(pid)
    return (copied(root, kAXFrontmostAttribute as CFString) as? NSNumber)?.boolValue == true
}

guard CommandLine.arguments.count == 2,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(168) }
let pid = pid_t(parsedPID)
let environment = ProcessInfo.processInfo.environment
guard let name = environment["ARC_NAME"], !name.isEmpty,
      let email = environment["ARC_EMAIL"], email.contains("@"),
      let password = environment["ARC_PASSWORD"], password.count >= 12 else { exit(169) }

var root = AXUIElementCreateApplication(pid)
let displayBounds = CGDisplayBounds(CGMainDisplayID())
guard let nameField = requireField(root, path: [0,0,6], identifier: "Name", secure: false),
      let emailField = requireField(root, path: [0,0,9], identifier: "Email", secure: false),
      let passwordField = requireField(root, path: [0,0,11], identifier: "Password", secure: true),
      let confirmField = requireField(root, path: [0,0,13], identifier: "Confirm Password", secure: true),
      createMatches(root, enabled: false),
      displayBounds.width > 0, displayBounds.height > 0,
      resolvePrivacy(root, displayBounds: displayBounds) != nil else { exit(170) }

let fields = [nameField, emailField, passwordField, confirmField]
func clearFields() -> Bool {
    var cleared = true
    for field in fields {
        if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFTypeRef) != .success {
            cleared = false
        }
        guard let remaining = copied(field, kAXValueAttribute as CFString) as? String,
              remaining.isEmpty else {
            cleared = false
            continue
        }
    }
    return cleared
}

func failClosed(_ code: Int32) -> Never {
    let cleared = clearFields()
    unsetenv("ARC_NAME")
    unsetenv("ARC_EMAIL")
    unsetenv("ARC_PASSWORD")
    exit(cleared ? code : 199)
}

for field in fields {
    guard let initial = copied(field, kAXValueAttribute as CFString) as? String,
          initial.isEmpty else { failClosed(171) }
}

for (field, expected) in [(nameField, name), (emailField, email)] {
    guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          boolAttr(field, kAXFocusedAttribute as CFString) == true else { failClosed(172) }
    guard typeUnicode(expected, to: pid) else { failClosed(173) }
    guard let actual = copied(field, kAXValueAttribute as CFString) as? String,
          actual.utf16.count == expected.utf16.count,
          digest(actual) == digest(expected) else { failClosed(174) }
}

for (field, expected) in [(passwordField, password), (confirmField, password)] {
    guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          boolAttr(field, kAXFocusedAttribute as CFString) == true else { failClosed(172) }
    guard typeUnicode(expected, to: pid) else { failClosed(173) }
}

unsetenv("ARC_NAME")
unsetenv("ARC_EMAIL")
unsetenv("ARC_PASSWORD")
Thread.sleep(forTimeInterval: 2.0)

// Immediate preconditions for the first HID pair.
guard runningActive(pid) else { failClosed(175) }
guard workspaceFrontmost(pid) else { failClosed(176) }
guard axFrontmost(pid) else { failClosed(177) }
root = AXUIElementCreateApplication(pid)
guard createMatches(root, enabled: false),
      let before = resolvePrivacy(root, displayBounds: displayBounds) else { failClosed(178) }
guard postHIDClick(before.activation) else { failClosed(179) }

// Post-first predicates and immediate preconditions for the second HID pair.
guard runningActive(pid) else { failClosed(180) }
guard workspaceFrontmost(pid) else { failClosed(181) }
guard axFrontmost(pid) else { failClosed(182) }
root = AXUIElementCreateApplication(pid)
guard createMatches(root, enabled: true) else { failClosed(183) }
guard let selected = resolvePrivacy(root, displayBounds: displayBounds) else { failClosed(184) }
guard sameGeometry(before, selected) else { failClosed(185) }
guard postHIDClick(before.activation) else { failClosed(186) }

// Post-second predicates.
guard runningActive(pid) else { failClosed(187) }
guard workspaceFrontmost(pid) else { failClosed(188) }
guard axFrontmost(pid) else { failClosed(189) }
root = AXUIElementCreateApplication(pid)
guard createMatches(root, enabled: false) else { failClosed(190) }
guard let unselected = resolvePrivacy(root, displayBounds: displayBounds),
      sameGeometry(before, unselected) else { failClosed(191) }
guard clearFields() else { failClosed(192) }

print("field_focus_checks=4 verified_plain_fields=2 opaque_secure_fields=2 hid_mouse_down=2 hid_mouse_up=2 create_states=disabled_enabled_disabled create_press=0 cleared_fields=4 account_actions=0 object_actions=0 share_actions=0")

