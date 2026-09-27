import Foundation
import AppKit
import ApplicationServices

struct Node {
    let path: String
    let role: String
    let subrole: String
    let identifier: String
    let title: String
    let description: String
    let help: String
    let placeholder: String
    let enabled: String
    let settableValue: String
    let actions: String
}

func copyAttr(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ name: CFString) -> String {
    return (copyAttr(element, name) as? String) ?? ""
}

func boolAttr(_ element: AXUIElement, _ name: CFString) -> String {
    guard let n = copyAttr(element, name) as? NSNumber else { return "" }
    return n.boolValue ? "true" : "false"
}

func actions(_ element: AXUIElement) -> String {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success,
          let names = raw as? [String] else { return "" }
    return names.sorted().joined(separator: ",")
}

func settable(_ element: AXUIElement, _ name: CFString) -> String {
    var result = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, name, &result) == .success else { return "" }
    return result.boolValue ? "true" : "false"
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    return (copyAttr(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func clean(_ input: String) -> String {
    return input.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

func walk(_ root: AXUIElement, prefix: String) -> [Node] {
    var out: [Node] = []
    var seen = Set<CFHashCode>()
    func visit(_ element: AXUIElement, _ path: String, _ depth: Int) {
        guard depth <= 22 else { return }
        let hash = CFHash(element)
        guard !seen.contains(hash) else { return }
        seen.insert(hash)
        out.append(Node(
            path: path,
            role: stringAttr(element, kAXRoleAttribute as CFString),
            subrole: stringAttr(element, kAXSubroleAttribute as CFString),
            identifier: stringAttr(element, kAXIdentifierAttribute as CFString),
            title: stringAttr(element, kAXTitleAttribute as CFString),
            description: stringAttr(element, kAXDescriptionAttribute as CFString),
            help: stringAttr(element, kAXHelpAttribute as CFString),
            placeholder: stringAttr(element, kAXPlaceholderValueAttribute as CFString),
            enabled: boolAttr(element, kAXEnabledAttribute as CFString),
            settableValue: settable(element, kAXValueAttribute as CFString),
            actions: actions(element)
        ))
        for (index, child) in children(element).enumerated() {
            visit(child, "\(path)/\(index)", depth + 1)
        }
    }
    visit(root, prefix, 0)
    return out
}

func render(_ nodes: [Node]) {
    print("path\trole\tsubrole\tidentifier\ttitle\tdescription\thelp\tplaceholder\tenabled\tvalue_settable\tactions")
    for n in nodes {
        print([n.path, n.role, n.subrole, n.identifier, n.title, n.description,
               n.help, n.placeholder, n.enabled, n.settableValue, n.actions]
            .map(clean).joined(separator: "\t"))
    }
}

guard CommandLine.arguments.count == 2, let parsedPID = Int32(CommandLine.arguments[1]) else {
    fputs("usage: ax-map <pid>\n", stderr)
    exit(64)
}
let pid = pid_t(parsedPID)
guard AXIsProcessTrusted() else {
    fputs("ax_trusted=false\n", stderr)
    exit(65)
}
let app = AXUIElementCreateApplication(pid)
render(walk(app, prefix: "A"))
