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

func allNodes(_ root: AXUIElement) -> [(String, AXUIElement)] {
    var result: [(String, AXUIElement)] = []
    var seen = Set<CFHashCode>()
    func visit(_ element: AXUIElement, path: String, depth: Int) {
        guard depth <= 24 else { return }
        let identity = CFHash(element)
        guard !seen.contains(identity) else { return }
        seen.insert(identity)
        result.append((path, element))
        for (index, child) in children(element).enumerated() {
            visit(child, path: "\(path)/\(index)", depth: depth + 1)
        }
    }
    visit(root, path: "A", depth: 0)
    return result
}

func sendEscape(to pid: pid_t) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return false }
    down.postToPid(pid)
    up.postToPid(pid)
    return true
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

let query = "Move to Top Apps"
let root = AXUIElementCreateApplication(pid)
let baseline = allNodes(root)
let openItems = baseline.filter { _, element in
    stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "_NS:240"
        && stringAttr(element, kAXTitleAttribute as CFString) == "Open Command Bar"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && actions(element) == ["AXCancel", "AXPick", "AXPress"]
}
guard openItems.count == 1 else { exit(72) }

var overlayOpen = false
var cleanupComplete = false
defer {
    if overlayOpen && !cleanupComplete {
        let cleanupNodes = allNodes(AXUIElementCreateApplication(pid))
        for (_, element) in cleanupNodes where stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField" && isSettable(element, kAXValueAttribute as CFString) {
            _ = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFTypeRef)
        }
        _ = sendEscape(to: pid)
    }
}

guard AXUIElementPerformAction(openItems[0].1, kAXPressAction as CFString) == .success else { exit(73) }
overlayOpen = true
Thread.sleep(forTimeInterval: 2.0)
var current = allNodes(AXUIElementCreateApplication(pid))
var fields = current.filter { _, element in
    stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && boolAttr(element, kAXFocusedAttribute as CFString) == true
        && isSettable(element, kAXValueAttribute as CFString)
}
guard fields.count == 1 else { exit(74) }
guard typeUnicode(query, to: pid) else { exit(75) }
Thread.sleep(forTimeInterval: 4.0)

current = allNodes(AXUIElementCreateApplication(pid))
let tokens = ["top apps", "favorite", "move to"]
let candidates = current.filter { _, element in
    let identifier = stringAttr(element, kAXIdentifierAttribute as CFString)
    let text = [identifier,
                stringAttr(element, kAXTitleAttribute as CFString),
                stringAttr(element, kAXDescriptionAttribute as CFString),
                stringAttr(element, kAXHelpAttribute as CFString)]
        .joined(separator: " ").lowercased()
    return identifier.lowercased().contains("commandbarselectedsuggestion")
        || tokens.contains(where: { text.contains($0) })
}

print("candidate_path\trole\tsubrole\tidentifier\ttitle\tdescription\thelp\tenabled\tactions")
for (path, element) in candidates {
    let row = [path,
               stringAttr(element, kAXRoleAttribute as CFString),
               stringAttr(element, kAXSubroleAttribute as CFString),
               stringAttr(element, kAXIdentifierAttribute as CFString),
               stringAttr(element, kAXTitleAttribute as CFString),
               stringAttr(element, kAXDescriptionAttribute as CFString),
               stringAttr(element, kAXHelpAttribute as CFString),
               boolAttr(element, kAXEnabledAttribute as CFString).map { $0 ? "true" : "false" } ?? "",
               actions(element).joined(separator: ",")]
    print(row.map(clean).joined(separator: "\t"))
}

fields = current.filter { _, element in
    stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && isSettable(element, kAXValueAttribute as CFString)
}
guard fields.count == 1,
      AXUIElementSetAttributeValue(fields[0].1, kAXValueAttribute as CFString, "" as CFTypeRef) == .success else { exit(76) }
Thread.sleep(forTimeInterval: 1.0)
guard sendEscape(to: pid) else { exit(77) }
Thread.sleep(forTimeInterval: 2.0)
let finalNodes = allNodes(AXUIElementCreateApplication(pid))
guard finalNodes.filter({ _, element in stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField" }).isEmpty else { exit(78) }
cleanupComplete = true
print("summary\tquery=Move_to_Top_Apps\topen_command_press=1\tunicode_events=32\tvalue_sets=1\tescape_events=2\tcandidate_rows=\(candidates.count)\tcandidate_presses=0\tfavorite_actions=0\tpreview_actions=0\tprovider_actions=0\teasel_actions=0")
