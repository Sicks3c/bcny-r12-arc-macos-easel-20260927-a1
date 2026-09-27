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

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(230) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(231) }
var root = AXUIElementCreateApplication(pid)
guard let menuSignin = nodeAt(root, [1,9,0,19]),
      stringAttr(menuSignin, kAXRoleAttribute as CFString) == "AXMenuItem",
      stringAttr(menuSignin, kAXIdentifierAttribute as CFString) == "makeKeyAndOrderFront:",
      stringAttr(menuSignin, kAXTitleAttribute as CFString) == "Sign In to Arc",
      boolAttr(menuSignin, kAXEnabledAttribute as CFString) == true,
      actions(menuSignin) == ["AXCancel", "AXPick", "AXPress"],
      AXUIElementPerformAction(menuSignin, kAXPressAction as CFString) == .success else { exit(232) }
print("action=menu_signin path=1/9/0/19 result=success")
Thread.sleep(forTimeInterval: 8.0)

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(233) }
root = AXUIElementCreateApplication(pid)
guard let right = nodeAt(root, [0,0,21]),
      stringAttr(right, kAXRoleAttribute as CFString) == "AXButton",
      stringAttr(right, kAXTitleAttribute as CFString) == "",
      stringAttr(right, kAXDescriptionAttribute as CFString) == "Right",
      boolAttr(right, kAXEnabledAttribute as CFString) == true,
      actions(right) == ["AXPress"],
      AXUIElementPerformAction(right, kAXPressAction as CFString) == .success else { exit(234) }
print("action=right path=0/0/21 result=success")
Thread.sleep(forTimeInterval: 8.0)

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(235) }
root = AXUIElementCreateApplication(pid)
guard let formSignin = nodeAt(root, [0,0,16]),
      stringAttr(formSignin, kAXRoleAttribute as CFString) == "AXButton",
      stringAttr(formSignin, kAXTitleAttribute as CFString) == "",
      stringAttr(formSignin, kAXDescriptionAttribute as CFString) == "Sign in",
      boolAttr(formSignin, kAXEnabledAttribute as CFString) == true,
      actions(formSignin) == ["AXPress"],
      AXUIElementPerformAction(formSignin, kAXPressAction as CFString) == .success else { exit(236) }
print("action=form_signin path=0/0/16 result=success")
Thread.sleep(forTimeInterval: 8.0)
print("navigation_actions=3 ax_values_read=0 ax_values_written=0 keyboard_events=0 screenshots=0 account_state_actions=0 object_actions=0 share_actions=0")

