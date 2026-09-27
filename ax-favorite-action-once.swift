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

func sendKey(_ key: CGKeyCode, to pid: pid_t) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
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

func exactMenuItem(_ nodes: [(String, AXUIElement)], identifier: String, title: String) -> [AXUIElement] {
    return nodes.compactMap { _, element in
        guard stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem",
              stringAttr(element, kAXIdentifierAttribute as CFString) == identifier,
              stringAttr(element, kAXTitleAttribute as CFString) == title,
              boolAttr(element, kAXEnabledAttribute as CFString) == true,
              actions(element) == ["AXCancel", "AXPick", "AXPress"] else { return nil }
        return element
    }
}

func press(_ element: AXUIElement) -> Bool {
    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
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
var nodes = allNodes(root)
let baselineEmpty = nodes.filter { _, element in
    stringAttr(element, kAXIdentifierAttribute as CFString) == "sidebarFavoritesEmptyStateDismissButton"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && actions(element) == ["AXPress"]
}
guard baselineEmpty.count == 1 else { exit(72) }
let newTabs = exactMenuItem(nodes, identifier: "newTabMenuItem", title: "New Tab…")
guard newTabs.count == 1 else { exit(73) }

var disposableTabCreated = false
var overlayOpen = false
var moveSubmitted = false
var disposableTabClosed = false
defer {
    if overlayOpen && !moveSubmitted {
        let cleanupNodes = allNodes(AXUIElementCreateApplication(pid))
        for (_, element) in cleanupNodes where stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField" && isSettable(element, kAXValueAttribute as CFString) {
            _ = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFTypeRef)
        }
        _ = sendKey(53, to: pid)
    }
    if disposableTabCreated && !disposableTabClosed {
        let cleanupNodes = allNodes(AXUIElementCreateApplication(pid))
        let cleanupClose = exactMenuItem(cleanupNodes, identifier: "_NS:968", title: "Close Tab")
        if cleanupClose.count == 1 { _ = press(cleanupClose[0]) }
    }
}

guard press(newTabs[0]) else { exit(74) }
disposableTabCreated = true
Thread.sleep(forTimeInterval: 3.0)

nodes = allNodes(AXUIElementCreateApplication(pid))
let closesBefore = exactMenuItem(nodes, identifier: "_NS:968", title: "Close Tab")
let openItems = exactMenuItem(nodes, identifier: "_NS:240", title: "Open Command Bar")
guard closesBefore.count == 1, openItems.count == 1 else { exit(75) }
guard press(openItems[0]) else { exit(76) }
overlayOpen = true
Thread.sleep(forTimeInterval: 2.0)

nodes = allNodes(AXUIElementCreateApplication(pid))
let fields = nodes.filter { _, element in
    stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && boolAttr(element, kAXFocusedAttribute as CFString) == true
        && isSettable(element, kAXValueAttribute as CFString)
}
guard fields.count == 1, typeUnicode(query, to: pid) else { exit(77) }
Thread.sleep(forTimeInterval: 4.0)
guard sendKey(125, to: pid) else { exit(78) }
Thread.sleep(forTimeInterval: 1.0)

nodes = allNodes(AXUIElementCreateApplication(pid))
let suggestionTables = nodes.filter { _, element in
    stringAttr(element, kAXRoleAttribute as CFString) == "AXTable"
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarSuggestions"
}
guard suggestionTables.count == 1 else { exit(79) }
let selectedRows = (copied(suggestionTables[0].1, kAXSelectedRowsAttribute as CFString) as? [AXUIElement]) ?? []
guard selectedRows.count == 1,
      let selectedTuple = nodes.first(where: { CFEqual($0.1, selectedRows[0]) }) else { exit(80) }
let selectedPrefix = selectedTuple.0 + "/"
let selectedValues = nodes.compactMap { path, element -> String? in
    guard path.hasPrefix(selectedPrefix) else { return nil }
    let value = stringAttr(element, kAXValueAttribute as CFString)
    return value.isEmpty ? nil : value
}
guard selectedValues == [query] else { exit(81) }

guard sendKey(36, to: pid) else { exit(82) }
moveSubmitted = true
overlayOpen = false
Thread.sleep(forTimeInterval: 8.0)

nodes = allNodes(AXUIElementCreateApplication(pid))
guard nodes.filter({ _, element in stringAttr(element, kAXIdentifierAttribute as CFString) == "commandBarTextField" }).isEmpty else { exit(83) }
let movedEmpty = nodes.filter { _, element in
    stringAttr(element, kAXIdentifierAttribute as CFString) == "sidebarFavoritesEmptyStateDismissButton"
}
let favoriteCollections = nodes.filter { _, element in
    stringAttr(element, kAXRoleAttribute as CFString) == "AXList"
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "sidebarFavoritesCollectionView"
}
guard favoriteCollections.count == 1 else { exit(84) }

let effectTokens = ["favorite", "top app", "move to", "pinned", "pin tab", "close tab"]
let effectNodes = nodes.filter { _, element in
    let text = [stringAttr(element, kAXIdentifierAttribute as CFString),
                stringAttr(element, kAXTitleAttribute as CFString),
                stringAttr(element, kAXDescriptionAttribute as CFString),
                stringAttr(element, kAXHelpAttribute as CFString)]
        .joined(separator: " ").lowercased()
    return effectTokens.contains(where: { text.contains($0) })
}
print("effect_path\trole\tsubrole\tidentifier\ttitle\tdescription\thelp\tenabled\tactions")
for (path, element) in effectNodes {
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

let favoritePath = favoriteCollections[0].0
let favoriteNodes = nodes.filter { path, _ in path == favoritePath || path.hasPrefix(favoritePath + "/") }
print("favorite_path\trole\tsubrole\tidentifier\ttitle\tdescription\thelp\tenabled\tactions")
for (path, element) in favoriteNodes {
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

let closesAfter = exactMenuItem(nodes, identifier: "_NS:968", title: "Close Tab")
guard closesAfter.count == 1, press(closesAfter[0]) else { exit(85) }
disposableTabClosed = true
Thread.sleep(forTimeInterval: 8.0)

nodes = allNodes(AXUIElementCreateApplication(pid))
let restoredEmpty = nodes.filter { _, element in
    stringAttr(element, kAXIdentifierAttribute as CFString) == "sidebarFavoritesEmptyStateDismissButton"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && actions(element) == ["AXPress"]
}
guard restoredEmpty.count == 1 else { exit(86) }
print("summary\tnew_tab_presses=1\topen_command_presses=1\tquery_unicode_events=32\tselection_down_events=2\tselected_exact_move_rows=1\treturn_events=2\tfavorite_actions=1\tpost_return_empty_state_rows=\(movedEmpty.count)\tpost_return_effect_rows=\(effectNodes.count)\tclose_tab_presses=1\tdisposable_tab_closed=true\trestored_empty_favorites=true\tfavorite_nodes_after_move=\(favoriteNodes.count)\tpreview_actions=0\tprovider_actions=0\teasel_actions=0")
