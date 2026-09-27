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

func nodeAt(_ root: AXUIElement, _ indices: [Int]) -> AXUIElement? {
    var node = root
    for index in indices {
        let kids = children(node)
        guard index >= 0 && index < kids.count else { return nil }
        node = kids[index]
    }
    return node
}

func requireField(_ root: AXUIElement, path: [Int], identifier: String, secure: Bool) -> AXUIElement {
    guard let field = nodeAt(root, path),
          stringAttr(field, kAXRoleAttribute as CFString) == "AXTextField",
          stringAttr(field, kAXIdentifierAttribute as CFString) == identifier,
          stringAttr(field, kAXSubroleAttribute as CFString) == (secure ? "AXSecureTextField" : ""),
          boolAttr(field, kAXEnabledAttribute as CFString) == true,
          isSettable(field, kAXValueAttribute as CFString),
          actions(field) == ["AXConfirm", "AXShowMenu"] else { exit(81) }
    return field
}

guard CommandLine.arguments.count == 2,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(80) }
let environment = ProcessInfo.processInfo.environment
guard let name = environment["ARC_NAME"], !name.isEmpty,
      let email = environment["ARC_EMAIL"], email.contains("@"),
      let password = environment["ARC_PASSWORD"], password.count >= 12 else { exit(82) }

var root = AXUIElementCreateApplication(pid_t(parsedPID))
let nameField = requireField(root, path: [0,0,6], identifier: "Name", secure: false)
let emailField = requireField(root, path: [0,0,9], identifier: "Email", secure: false)
let passwordField = requireField(root, path: [0,0,11], identifier: "Password", secure: true)
let confirmField = requireField(root, path: [0,0,13], identifier: "Confirm Password", secure: true)
guard let initialCreate = nodeAt(root, [0,0,15]),
      stringAttr(initialCreate, kAXRoleAttribute as CFString) == "AXButton",
      stringAttr(initialCreate, kAXTitleAttribute as CFString) == "",
      stringAttr(initialCreate, kAXDescriptionAttribute as CFString) == "Create an account",
      boolAttr(initialCreate, kAXEnabledAttribute as CFString) == false,
      actions(initialCreate) == ["AXPress"] else { exit(83) }
guard let privacy = nodeAt(root, [0,0,14]),
      stringAttr(privacy, kAXRoleAttribute as CFString) == "AXUnknown",
      stringAttr(privacy, kAXIdentifierAttribute as CFString) == "PrivacyCheckbox",
      actions(privacy).isEmpty else { exit(84) }

for (field, value) in [(nameField, name), (emailField, email), (passwordField, password), (confirmField, password)] {
    guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFTypeRef) == .success else { exit(85) }
}
unsetenv("ARC_NAME")
unsetenv("ARC_EMAIL")
unsetenv("ARC_PASSWORD")
Thread.sleep(forTimeInterval: 2.0)

root = AXUIElementCreateApplication(pid_t(parsedPID))
guard let enabledCreate = nodeAt(root, [0,0,15]),
      stringAttr(enabledCreate, kAXRoleAttribute as CFString) == "AXButton",
      stringAttr(enabledCreate, kAXDescriptionAttribute as CFString) == "Create an account",
      boolAttr(enabledCreate, kAXEnabledAttribute as CFString) == true,
      actions(enabledCreate) == ["AXPress"] else { exit(86) }
guard AXUIElementPerformAction(enabledCreate, kAXPressAction as CFString) == .success else { exit(87) }
print("signup_fields=4 signup_values_read=0 create_path=0/0/15 create_press=success privacy_actions=0")

