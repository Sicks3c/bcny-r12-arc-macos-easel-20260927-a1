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

func settableState(_ element: AXUIElement, _ name: CFString) -> Bool? {
    var result = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, name, &result) == .success else { return nil }
    return result.boolValue
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

func allNodes(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var seen = Set<CFHashCode>()
    func visit(_ element: AXUIElement, depth: Int) {
        guard depth <= 22 else { return }
        let hash = CFHash(element)
        guard !seen.contains(hash) else { return }
        seen.insert(hash)
        result.append(element)
        for child in children(element) {
            visit(child, depth: depth + 1)
        }
    }
    visit(root, depth: 0)
    return result
}

func processGate(_ pid: pid_t, expectedExecutable: String) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid),
          !app.isTerminated,
          app.bundleIdentifier == "company.thebrowser.Browser",
          app.executableURL?.standardizedFileURL.path == expectedExecutable,
          app.isActive,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    return boolAttr(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString) == true
}

func exactMenuItem(_ element: AXUIElement, identifier: String, title: String, enabled: Bool = true) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == identifier
        && stringAttr(element, kAXTitleAttribute as CFString) == title
        && stringAttr(element, kAXDescriptionAttribute as CFString) == ""
        && boolAttr(element, kAXEnabledAttribute as CFString) == enabled
        && settableState(element, kAXValueAttribute as CFString) == false
        && actions(element) == ["AXCancel", "AXPick", "AXPress"]
}

func loginFormExactHits(_ nodes: [AXUIElement]) -> Int {
    return nodes.filter { element in
        let role = stringAttr(element, kAXRoleAttribute as CFString)
        let subrole = stringAttr(element, kAXSubroleAttribute as CFString)
        let identifier = stringAttr(element, kAXIdentifierAttribute as CFString)
        let description = stringAttr(element, kAXDescriptionAttribute as CFString)
        return (role == "AXTextField" && subrole == "" && identifier == "Email")
            || (role == "AXTextField" && subrole == "AXSecureTextField" && identifier == "Password")
            || (role == "AXButton" && description == "Sign in")
    }.count
}

func isSearchEasels(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXTextField"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == ""
        && stringAttr(element, kAXTitleAttribute as CFString) == ""
        && stringAttr(element, kAXDescriptionAttribute as CFString) == ""
        && stringAttr(element, kAXPlaceholderValueAttribute as CFString) == "Search Easels…"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settableState(element, kAXValueAttribute as CFString) == true
        && actions(element) == ["AXConfirm", "AXShowMenu"]
}

func isEaselsButton(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXButton"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == ""
        && stringAttr(element, kAXTitleAttribute as CFString) == ""
        && stringAttr(element, kAXDescriptionAttribute as CFString) == "Easels"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settableState(element, kAXValueAttribute as CFString) == false
        && actions(element) == ["AXPress"]
}

func exactEmptyOverlay(_ root: AXUIElement) -> Bool {
    let nodes = allNodes(root)
    guard let signOut = nodeAt(root, [1,1,0,15]),
          exactMenuItem(signOut, identifier: "_NS:1753", title: "Sign Out"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:1753", title: "Sign Out") }).count == 1,
          loginFormExactHits(nodes) == 0,
          let overlay = nodeAt(root, [0,0]),
          stringAttr(overlay, kAXRoleAttribute as CFString) == "AXGroup",
          stringAttr(overlay, kAXSubroleAttribute as CFString) == "AXHostingView",
          children(overlay).count == 16,
          let search = nodeAt(root, [0,0,4]), isSearchEasels(search),
          nodes.filter(isSearchEasels).count == 1,
          let easels = nodeAt(root, [0,0,7]), isEaselsButton(easels),
          nodes.filter(isEaselsButton).count == 1,
          let close = nodeAt(root, [1,9,0,13]),
          exactMenuItem(close, identifier: "_NS:451", title: "Close Library"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:451", title: "Close Library") }).count == 1,
          let hide = nodeAt(root, [1,9,0,15]),
          exactMenuItem(hide, identifier: "_NS:1516", title: "Hide Easels"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:1516", title: "Hide Easels") }).count == 1 else { return false }
    let itemRoles = Set(["AXRow", "AXCell", "AXList", "AXOutline", "AXTable"])
    guard allNodes(overlay).filter({ itemRoles.contains(stringAttr($0, kAXRoleAttribute as CFString)) }).isEmpty,
          nodes.filter({ stringAttr($0, kAXRoleAttribute as CFString) == "AXMenuItem"
              && stringAttr($0, kAXTitleAttribute as CFString) == "Delete"
              && boolAttr($0, kAXEnabledAttribute as CFString) == true }).isEmpty else { return false }
    return true
}

func exactClosedState(_ root: AXUIElement) -> AXUIElement? {
    let nodes = allNodes(root)
    guard let signOut = nodeAt(root, [1,1,0,15]),
          exactMenuItem(signOut, identifier: "_NS:1753", title: "Sign Out"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:1753", title: "Sign Out") }).count == 1,
          loginFormExactHits(nodes) == 0,
          nodes.filter(isSearchEasels).isEmpty,
          nodes.filter({ exactMenuItem($0, identifier: "_NS:451", title: "Close Library") }).isEmpty,
          nodes.filter({ exactMenuItem($0, identifier: "_NS:1516", title: "Hide Easels") }).isEmpty,
          let openLibrary = nodeAt(root, [1,9,0,13]),
          exactMenuItem(openLibrary, identifier: "_NS:451", title: "Open Library…"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:451", title: "Open Library…") }).count == 1,
          let viewEasels = nodeAt(root, [1,9,0,15]),
          exactMenuItem(viewEasels, identifier: "_NS:1516", title: "View Easels…"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:1516", title: "View Easels…") }).count == 1,
          let newEasel = nodeAt(root, [1,2,0,10]),
          exactMenuItem(newEasel, identifier: "newEaselMenuItemId", title: "New Easel"),
          nodes.filter({ exactMenuItem($0, identifier: "newEaselMenuItemId", title: "New Easel") }).count == 1 else { return nil }
    return newEasel
}

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(68) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(69) }
var root = AXUIElementCreateApplication(pid)
guard exactEmptyOverlay(root) else { exit(70) }
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(71) }
root = AXUIElementCreateApplication(pid)
guard exactEmptyOverlay(root),
      let currentCloseLibrary = nodeAt(root, [1,9,0,13]),
      exactMenuItem(currentCloseLibrary, identifier: "_NS:451", title: "Close Library") else { exit(72) }
guard AXUIElementPerformAction(currentCloseLibrary, kAXPressAction as CFString) == .success else { exit(73) }

Thread.sleep(forTimeInterval: 5.0)
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(74) }
root = AXUIElementCreateApplication(pid)
guard exactClosedState(root) != nil else { exit(75) }
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(76) }
root = AXUIElementCreateApplication(pid)
guard let currentNewEasel = exactClosedState(root) else { exit(77) }
guard AXUIElementPerformAction(currentNewEasel, kAXPressAction as CFString) == .success else { exit(78) }

print("prestate=exact_empty_easels_overlay item_structural_roles=0 enabled_delete_rows=0 close_library_path=A/1/9/0/13 close_library_press=1 close_library_retries=0 new_easel_unique_enabled=1 new_easel_path=A/1/2/0/10 new_easel_identifier=newEaselMenuItemId new_easel_press=1 new_easel_retries=0 objects_created_max=1 content_actions=0 marker_actions=0 share_actions=0 context_menu_actions=0 right_clicks=0 delete_actions=0 confirm_actions=0 cancel_actions=0 screenshots=0")
