import Foundation
import AppKit
import ApplicationServices
import CryptoKit

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
        CGEventPostToPid(pid, down)
        CGEventPostToPid(pid, up)
        Thread.sleep(forTimeInterval: 0.025)
    }
    return true
}

guard CommandLine.arguments.count == 2,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(100) }
let pid = pid_t(parsedPID)
let environment = ProcessInfo.processInfo.environment
guard let name = environment["ARC_NAME"], !name.isEmpty,
      let email = environment["ARC_EMAIL"], email.contains("@"),
      let password = environment["ARC_PASSWORD"], password.count >= 12 else { exit(101) }

var root = AXUIElementCreateApplication(pid)
guard let nameField = requireField(root, path: [0,0,6], identifier: "Name", secure: false),
      let emailField = requireField(root, path: [0,0,9], identifier: "Email", secure: false),
      let passwordField = requireField(root, path: [0,0,11], identifier: "Password", secure: true),
      let confirmField = requireField(root, path: [0,0,13], identifier: "Confirm Password", secure: true),
      let initialCreate = nodeAt(root, [0,0,15]),
      stringAttr(initialCreate, kAXRoleAttribute as CFString) == "AXButton",
      stringAttr(initialCreate, kAXDescriptionAttribute as CFString) == "Create an account",
      boolAttr(initialCreate, kAXEnabledAttribute as CFString) == false,
      actions(initialCreate) == ["AXPress"],
      let privacy = nodeAt(root, [0,0,14]),
      stringAttr(privacy, kAXRoleAttribute as CFString) == "AXUnknown",
      stringAttr(privacy, kAXIdentifierAttribute as CFString) == "PrivacyCheckbox",
      actions(privacy).isEmpty,
      !hasSettableAttribute(privacy) else { exit(102) }

let fields = [nameField, emailField, passwordField, confirmField]
func failClosed(_ code: Int32) -> Never {
    var cleared = true
    for field in fields {
        if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFTypeRef) != .success {
            cleared = false
        }
        if let remaining = copied(field, kAXValueAttribute as CFString) as? String,
           !remaining.isEmpty {
            cleared = false
        }
    }
    unsetenv("ARC_NAME")
    unsetenv("ARC_EMAIL")
    unsetenv("ARC_PASSWORD")
    exit(cleared ? code : 199)
}

for field in fields {
    guard let initial = copied(field, kAXValueAttribute as CFString) as? String,
          initial.isEmpty else { failClosed(108) }
}

for (field, expected) in [(nameField, name), (emailField, email), (passwordField, password), (confirmField, password)] {
    guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          boolAttr(field, kAXFocusedAttribute as CFString) == true else { failClosed(103) }
    guard typeUnicode(expected, to: pid) else { failClosed(104) }
    guard let actual = copied(field, kAXValueAttribute as CFString) as? String,
          actual.utf16.count == expected.utf16.count,
          digest(actual) == digest(expected) else { failClosed(105) }
}
unsetenv("ARC_NAME")
unsetenv("ARC_EMAIL")
unsetenv("ARC_PASSWORD")
Thread.sleep(forTimeInterval: 2.0)

root = AXUIElementCreateApplication(pid)
guard let enabledCreate = nodeAt(root, [0,0,15]),
      stringAttr(enabledCreate, kAXRoleAttribute as CFString) == "AXButton",
      stringAttr(enabledCreate, kAXDescriptionAttribute as CFString) == "Create an account",
      boolAttr(enabledCreate, kAXEnabledAttribute as CFString) == true,
      actions(enabledCreate) == ["AXPress"] else { failClosed(106) }
guard AXUIElementPerformAction(enabledCreate, kAXPressAction as CFString) == .success else { failClosed(107) }
print("input=pid_scoped_unicode fields=4 focus_checks=4 in_memory_length_hash_checks=4 values_logged=0 create_press=1")
