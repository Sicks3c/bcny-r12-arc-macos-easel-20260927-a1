import Foundation
import AppKit
import ApplicationServices

func copied(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    return (copied(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
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

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(90) }
let indices = CommandLine.arguments[2].split(separator: ",").compactMap { Int($0) }
guard !indices.isEmpty,
      let node = nodeAt(AXUIElementCreateApplication(pid_t(parsedPID)), indices) else { exit(91) }

var rawNames: CFArray?
guard AXUIElementCopyAttributeNames(node, &rawNames) == .success,
      let names = rawNames as? [String] else { exit(92) }
print("attribute_count=\(names.count)")
for name in names.sorted() {
    var settable = DarwinBoolean(false)
    let rc = AXUIElementIsAttributeSettable(node, name as CFString, &settable)
    print("attribute=\(name) settable_rc=\(rc.rawValue) settable=\(settable.boolValue)")
}

var rawParameterized: CFArray?
if AXUIElementCopyParameterizedAttributeNames(node, &rawParameterized) == .success,
   let parameterized = rawParameterized as? [String] {
    print("parameterized_count=\(parameterized.count)")
    for name in parameterized.sorted() { print("parameterized=\(name)") }
} else {
    print("parameterized_count=0")
}

var rawActions: CFArray?
if AXUIElementCopyActionNames(node, &rawActions) == .success,
   let actions = rawActions as? [String] {
    print("action_count=\(actions.count)")
    for name in actions.sorted() { print("action=\(name)") }
} else {
    print("action_count=0")
}
print("attribute_values_read=0")
print("actions_performed=0")

