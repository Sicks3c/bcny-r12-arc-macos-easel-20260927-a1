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

func settableState(_ element: AXUIElement, _ name: CFString) -> Bool? {
    var result = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, name, &result) == .success else { return nil }
    return result.boolValue
}

func isSettable(_ element: AXUIElement, _ name: CFString) -> Bool {
    return settableState(element, name) == true
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

func processGate(_ pid: pid_t, expectedExecutable: String) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid),
          !app.isTerminated,
          app.bundleIdentifier == "company.thebrowser.Browser",
          app.executableURL?.standardizedFileURL.path == expectedExecutable,
          app.isActive,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    let root = AXUIElementCreateApplication(pid)
    return boolAttr(root, kAXFrontmostAttribute as CFString) == true
}

func requireWindow(_ root: AXUIElement) -> AXUIElement? {
    guard let window = nodeAt(root, [0]),
          stringAttr(window, kAXRoleAttribute as CFString) == "AXWindow",
          stringAttr(window, kAXSubroleAttribute as CFString) == "AXStandardWindow",
          stringAttr(window, kAXIdentifierAttribute as CFString) == "",
          stringAttr(window, kAXTitleAttribute as CFString) == "Sign In to Arc",
          boolAttr(window, kAXEnabledAttribute as CFString) == nil,
          actions(window) == ["AXRaise"] else { return nil }
    return window
}

func requireField(_ root: AXUIElement, path: [Int], identifier: String, secure: Bool) -> AXUIElement? {
    guard requireWindow(root) != nil,
          let field = nodeAt(root, path),
          stringAttr(field, kAXRoleAttribute as CFString) == "AXTextField",
          stringAttr(field, kAXSubroleAttribute as CFString) == (secure ? "AXSecureTextField" : ""),
          stringAttr(field, kAXIdentifierAttribute as CFString) == identifier,
          stringAttr(field, kAXTitleAttribute as CFString) == "",
          stringAttr(field, kAXDescriptionAttribute as CFString) == "",
          boolAttr(field, kAXEnabledAttribute as CFString) == true,
          isSettable(field, kAXFocusedAttribute as CFString),
          isSettable(field, kAXValueAttribute as CFString),
          actions(field) == ["AXConfirm", "AXShowMenu"] else { return nil }
    return field
}

func requireSignIn(_ root: AXUIElement, enabled: Bool) -> AXUIElement? {
    guard requireWindow(root) != nil,
          let button = nodeAt(root, [0,0,10]),
          stringAttr(button, kAXRoleAttribute as CFString) == "AXButton",
          stringAttr(button, kAXSubroleAttribute as CFString) == "",
          stringAttr(button, kAXIdentifierAttribute as CFString) == "",
          stringAttr(button, kAXTitleAttribute as CFString) == "",
          stringAttr(button, kAXDescriptionAttribute as CFString) == "Sign in",
          boolAttr(button, kAXEnabledAttribute as CFString) == enabled,
          settableState(button, kAXValueAttribute as CFString) == false,
          actions(button) == ["AXPress"] else { return nil }
    return button
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

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(240) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
let environment = ProcessInfo.processInfo.environment
guard let email = environment["ARC_EMAIL"], email.contains("@"),
      let password = environment["ARC_PASSWORD"], password.count >= 12 else { exit(241) }

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(242) }
var root = AXUIElementCreateApplication(pid)
guard let initialEmail = requireField(root, path: [0,0,6], identifier: "Email", secure: false),
      let initialPassword = requireField(root, path: [0,0,8], identifier: "Password", secure: true),
      requireSignIn(root, enabled: false) != nil else { exit(243) }

let fields = [initialEmail, initialPassword]
func cleared(_ field: AXUIElement) -> Bool {
    guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFTypeRef) == .success,
          let remaining = copied(field, kAXValueAttribute as CFString) as? String,
          remaining.isEmpty else { return false }
    return true
}

func failClosed(_ code: Int32) -> Never {
    var clean = true
    for field in fields where !cleared(field) {
        clean = false
    }
    unsetenv("ARC_EMAIL")
    unsetenv("ARC_PASSWORD")
    Thread.sleep(forTimeInterval: 1.0)
    let current = AXUIElementCreateApplication(pid)
    guard clean,
          let emailField = requireField(current, path: [0,0,6], identifier: "Email", secure: false),
          let passwordField = requireField(current, path: [0,0,8], identifier: "Password", secure: true),
          let emailValue = copied(emailField, kAXValueAttribute as CFString) as? String,
          emailValue.isEmpty,
          let passwordValue = copied(passwordField, kAXValueAttribute as CFString) as? String,
          passwordValue.isEmpty,
          requireSignIn(current, enabled: false) != nil else { exit(299) }
    exit(code)
}

guard let initialEmailValue = copied(initialEmail, kAXValueAttribute as CFString) as? String,
      initialEmailValue.isEmpty,
      let initialPasswordValue = copied(initialPassword, kAXValueAttribute as CFString) as? String,
      initialPasswordValue.isEmpty else { failClosed(244) }

guard processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(245) }
root = AXUIElementCreateApplication(pid)
guard let emailField = requireField(root, path: [0,0,6], identifier: "Email", secure: false),
      AXUIElementSetAttributeValue(emailField, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
      boolAttr(emailField, kAXFocusedAttribute as CFString) == true,
      processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(246) }
root = AXUIElementCreateApplication(pid)
guard let focusedEmail = requireField(root, path: [0,0,6], identifier: "Email", secure: false),
      boolAttr(focusedEmail, kAXFocusedAttribute as CFString) == true,
      typeUnicode(email, to: pid) else { failClosed(247) }

guard processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(248) }
root = AXUIElementCreateApplication(pid)
guard let populatedEmail = requireField(root, path: [0,0,6], identifier: "Email", secure: false),
      let actualEmail = copied(populatedEmail, kAXValueAttribute as CFString) as? String,
      actualEmail.utf16.count == email.utf16.count,
      digest(actualEmail) == digest(email),
      requireSignIn(root, enabled: false) != nil else { failClosed(249) }

guard processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(250) }
root = AXUIElementCreateApplication(pid)
guard let passwordField = requireField(root, path: [0,0,8], identifier: "Password", secure: true),
      AXUIElementSetAttributeValue(passwordField, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
      boolAttr(passwordField, kAXFocusedAttribute as CFString) == true,
      processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(251) }
root = AXUIElementCreateApplication(pid)
guard let focusedPassword = requireField(root, path: [0,0,8], identifier: "Password", secure: true),
      boolAttr(focusedPassword, kAXFocusedAttribute as CFString) == true,
      typeUnicode(password, to: pid) else { failClosed(252) }

unsetenv("ARC_EMAIL")
unsetenv("ARC_PASSWORD")
Thread.sleep(forTimeInterval: 2.0)
guard processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(253) }
root = AXUIElementCreateApplication(pid)
guard let enabledEmail = requireField(root, path: [0,0,6], identifier: "Email", secure: false),
      let enabledPassword = requireField(root, path: [0,0,8], identifier: "Password", secure: true),
      requireSignIn(root, enabled: true) != nil else { failClosed(254) }

guard processGate(pid, expectedExecutable: expectedExecutable),
      cleared(enabledEmail),
      processGate(pid, expectedExecutable: expectedExecutable),
      cleared(enabledPassword) else { failClosed(255) }
Thread.sleep(forTimeInterval: 2.0)
guard processGate(pid, expectedExecutable: expectedExecutable) else { failClosed(256) }
root = AXUIElementCreateApplication(pid)
guard let clearedEmail = requireField(root, path: [0,0,6], identifier: "Email", secure: false),
      let clearedPassword = requireField(root, path: [0,0,8], identifier: "Password", secure: true),
      let clearedEmailValue = copied(clearedEmail, kAXValueAttribute as CFString) as? String,
      clearedEmailValue.isEmpty,
      let clearedPasswordValue = copied(clearedPassword, kAXValueAttribute as CFString) as? String,
      clearedPasswordValue.isEmpty,
      requireSignIn(root, enabled: false) != nil else { failClosed(257) }

print("input=pid_scoped_unicode fields=2 focus_checks=2 email_length_hash_checks=1 password_post_input_reads=0 sign_in_transitions=disabled_enabled_disabled sign_in_press=0 fields_cleared=2 values_logged=0 screenshots=0 account_state_actions=0 object_actions=0 share_actions=0 backend_actions=0")
