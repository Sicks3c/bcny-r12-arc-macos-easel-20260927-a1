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

func children(_ element: AXUIElement) -> [AXUIElement] {
    return (copied(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func actions(_ element: AXUIElement) -> [String] {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success,
          let names = raw as? [String] else { return [] }
    return names.sorted()
}

func nodeAt(_ root: AXUIElement, indices: [Int]) -> AXUIElement? {
    var node = root
    for index in indices {
        let kids = children(node)
        guard index >= 0 && index < kids.count else { return nil }
        node = kids[index]
    }
    return node
}

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]) else {
    fputs("usage: ax-step <pid> <right|signin>\n", stderr)
    exit(64)
}
guard AXIsProcessTrusted() else { exit(65) }
let root = AXUIElementCreateApplication(pid_t(parsedPID))
let stage = CommandLine.arguments[2]

if stage == "right" {
    guard let target = nodeAt(root, indices: [0, 0, 21]),
          stringAttr(target, kAXRoleAttribute as CFString) == "AXButton",
          stringAttr(target, kAXTitleAttribute as CFString) == "Right",
          stringAttr(target, kAXDescriptionAttribute as CFString) == "",
          actions(target) == ["AXPress"] else { exit(71) }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { exit(72) }
    print("action=right path=0/0/21 role=AXButton title=Right actions=AXPress result=success")
} else if stage == "signin" {
    guard let target = nodeAt(root, indices: [1, 9, 0, 19]),
          stringAttr(target, kAXRoleAttribute as CFString) == "AXMenuItem",
          stringAttr(target, kAXTitleAttribute as CFString) == "Sign In to Arc",
          stringAttr(target, kAXIdentifierAttribute as CFString) == "makeKeyAndOrderFront:",
          actions(target) == ["AXCancel", "AXPick", "AXPress"] else { exit(73) }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { exit(74) }
    print("action=signin path=1/9/0/19 role=AXMenuItem title=Sign_In_to_Arc result=success")
} else {
    exit(75)
}

