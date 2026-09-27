import Foundation
import AppKit
import ApplicationServices
import CryptoKit

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

func asString(_ value: CFTypeRef?) -> String? {
    if let text = value as? String { return text }
    if let url = value as? URL { return url.absoluteString }
    if let url = value as? NSURL { return url.absoluteString }
    return nil
}

func exactRoute(_ raw: String) -> (url: String, id: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let absolute = trimmed.hasPrefix("https://") ? trimmed : "https://" + trimmed
    guard let parts = URLComponents(string: absolute),
          parts.scheme == "https",
          parts.host?.lowercased() == "arc.net",
          parts.port == nil,
          parts.user == nil,
          parts.password == nil,
          parts.query == nil,
          parts.fragment == nil else { return nil }
    let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard segments.count == 2,
          segments[0] == "e",
          parts.percentEncodedPath == "/e/\(segments[1])",
          (8...128).contains(segments[1].utf8.count),
          segments[1].utf8.allSatisfy({ byte in
              (byte >= 48 && byte <= 57)
                  || (byte >= 65 && byte <= 90)
                  || (byte >= 97 && byte <= 122)
                  || byte == 45
                  || byte == 95
          }) else { return nil }
    return ("https://arc.net/e/\(segments[1])", segments[1])
}

func sha256(_ text: String) -> String {
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
      AXIsProcessTrusted() else { exit(79) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(80) }
let root = AXUIElementCreateApplication(pid)
var observed = Set<String>()
for node in allNodes(root) {
    for name in ["AXURL" as CFString, "AXDocument" as CFString] {
        if let raw = asString(copied(node, name)), let route = exactRoute(raw) {
            observed.insert(route.url)
        }
    }
    let role = stringAttr(node, kAXRoleAttribute as CFString)
    let identifier = stringAttr(node, kAXIdentifierAttribute as CFString)
    let placeholder = stringAttr(node, kAXPlaceholderValueAttribute as CFString)
    if role == "AXTextField" && (identifier.lowercased().contains("commandbar") || placeholder == "Search or Enter URL…"),
       let raw = asString(copied(node, kAXValueAttribute as CFString)),
       let route = exactRoute(raw) {
        observed.insert(route.url)
    }
}
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(81) }

if observed.count == 1, let url = observed.first, let route = exactRoute(url) {
    print("exact_route_candidates=1 url_utf8_length=\(url.utf8.count) id_utf8_length=\(route.id.utf8.count) url_sha256=\(sha256(url)) id_sha256=\(sha256(route.id)) raw_url_emitted=0 raw_id_emitted=0 clipboard_actions=0 copy_link_actions=0")
} else {
    print("exact_route_candidates=\(observed.count) url_utf8_length=0 id_utf8_length=0 url_sha256=absent id_sha256=absent raw_url_emitted=0 raw_id_emitted=0 clipboard_actions=0 copy_link_actions=0")
}
