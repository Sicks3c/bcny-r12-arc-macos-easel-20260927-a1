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
    let root = AXUIElementCreateApplication(pid)
    return boolAttr(root, kAXFrontmostAttribute as CFString) == true
}

func isSignOut(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "_NS:1753"
        && stringAttr(element, kAXTitleAttribute as CFString) == "Sign Out"
        && stringAttr(element, kAXDescriptionAttribute as CFString) == ""
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settableState(element, kAXValueAttribute as CFString) == false
        && actions(element) == ["AXCancel", "AXPick", "AXPress"]
}

func isViewEasels(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "_NS:1516"
        && stringAttr(element, kAXTitleAttribute as CFString) == "View Easels…"
        && stringAttr(element, kAXDescriptionAttribute as CFString) == ""
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
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

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(60) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(61) }
var root = AXUIElementCreateApplication(pid)
var nodes = allNodes(root)
guard let signOut = nodeAt(root, [1,1,0,15]),
      isSignOut(signOut),
      nodes.filter(isSignOut).count == 1 else { exit(62) }
guard loginFormExactHits(nodes) == 0 else { exit(63) }
guard let viewEasels = nodeAt(root, [1,9,0,15]),
      isViewEasels(viewEasels),
      nodes.filter(isViewEasels).count == 1 else { exit(64) }

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(65) }
root = AXUIElementCreateApplication(pid)
nodes = allNodes(root)
guard let currentSignOut = nodeAt(root, [1,1,0,15]),
      isSignOut(currentSignOut),
      nodes.filter(isSignOut).count == 1,
      loginFormExactHits(nodes) == 0,
      let currentViewEasels = nodeAt(root, [1,9,0,15]),
      isViewEasels(currentViewEasels),
      nodes.filter(isViewEasels).count == 1 else { exit(66) }

guard AXUIElementPerformAction(currentViewEasels, kAXPressAction as CFString) == .success else { exit(67) }

print("prestate=exact_signed_in_form_absent sign_out_exact_unique=1 view_easels_exact_unique=1 view_easels_path=A/1/9/0/15 view_easels_identifier=_NS:1516 title_codepoint=U+2026 view_easels_press=1 retries=0 post_press_actions=0 values_read=0 values_written=0 screenshots=0 context_menu_actions=0 right_clicks=0 delete_actions=0 new_easel_actions=0 share_actions=0 onboarding_actions=0 sign_out_actions=0")
