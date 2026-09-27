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

func boolAttr(_ element: AXUIElement, _ name: CFString) -> String {
    guard let value = copied(element, name) as? NSNumber else { return "" }
    return value.boolValue ? "true" : "false"
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    return (copied(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func actions(_ element: AXUIElement) -> String {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success,
          let names = raw as? [String] else { return "" }
    return names.sorted().joined(separator: ",")
}

func clean(_ value: String) -> String {
    return value.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(70) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
guard let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated,
      app.bundleIdentifier == "company.thebrowser.Browser",
      app.executableURL?.standardizedFileURL.path == expectedExecutable,
      app.isActive,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { exit(71) }

let tokens = ["favorite", "top app", "preview", "move to", "pinned", "pin tab", "outlook", "google calendar", "close tab"]
let root = AXUIElementCreateApplication(pid)
var seen = Set<CFHashCode>()
var rows: [[String]] = []

func visit(_ element: AXUIElement, path: String, depth: Int) {
    guard depth <= 24 else { return }
    let identity = CFHash(element)
    guard !seen.contains(identity) else { return }
    seen.insert(identity)
    let role = stringAttr(element, kAXRoleAttribute as CFString)
    let subrole = stringAttr(element, kAXSubroleAttribute as CFString)
    let identifier = stringAttr(element, kAXIdentifierAttribute as CFString)
    let title = stringAttr(element, kAXTitleAttribute as CFString)
    let description = stringAttr(element, kAXDescriptionAttribute as CFString)
    let help = stringAttr(element, kAXHelpAttribute as CFString)
    let searchable = [identifier, title, description, help].joined(separator: " ").lowercased()
    if tokens.contains(where: { searchable.contains($0) }) {
        rows.append([path, role, subrole, identifier, title, description, help,
                     boolAttr(element, kAXEnabledAttribute as CFString), actions(element)])
    }
    for (index, child) in children(element).enumerated() {
        visit(child, path: "\(path)/\(index)", depth: depth + 1)
    }
}

visit(root, path: "A", depth: 0)
print("path\trole\tsubrole\tidentifier\ttitle\tdescription\thelp\tenabled\tactions")
for row in rows.sorted(by: { $0[0] < $1[0] }) {
    print(row.map(clean).joined(separator: "\t"))
}
