import Foundation
import AppKit
import ApplicationServices

func copied(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ name: CFString) -> String {
    (copied(element, name) as? String) ?? ""
}

func boolAttr(_ element: AXUIElement, _ name: CFString) -> Bool? {
    (copied(element, name) as? NSNumber)?.boolValue
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (copied(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func actions(_ element: AXUIElement) -> [String] {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success,
          let names = raw as? [String] else { return [] }
    return names.sorted()
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
        for child in children(element) { visit(child, depth: depth + 1) }
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

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(120) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(121) }

let root = AXUIElementCreateApplication(pid)
let nodes = allNodes(root)
let signOut = nodes.filter {
    stringAttr($0, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr($0, kAXIdentifierAttribute as CFString) == "_NS:1753"
        && boolAttr($0, kAXEnabledAttribute as CFString) == true
        && actions($0) == ["AXCancel", "AXPick", "AXPress"]
}
let newEasel = nodes.filter {
    stringAttr($0, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr($0, kAXIdentifierAttribute as CFString) == "newEaselMenuItemId"
        && boolAttr($0, kAXEnabledAttribute as CFString) == true
        && actions($0) == ["AXCancel", "AXPick", "AXPress"]
}
let signIn = nodes.filter {
    stringAttr($0, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr($0, kAXIdentifierAttribute as CFString) == "makeKeyAndOrderFront:"
        && boolAttr($0, kAXEnabledAttribute as CFString) == true
}

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(122) }
let pass = signOut.count == 1 && newEasel.count == 1 && signIn.count == 0
print("schema=1 signed_in_gate=\(pass ? "PASS" : "FAIL") sign_out_identifier_count=\(signOut.count) enabled_new_easel_identifier_count=\(newEasel.count) enabled_sign_in_identifier_count=\(signIn.count) title_reads=0 description_reads=0 value_reads=0 actions_performed=0")
guard pass else { exit(123) }
