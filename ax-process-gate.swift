import Foundation
import AppKit
import ApplicationServices

func copied(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(120) }

let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
guard let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated,
      app.bundleIdentifier == "company.thebrowser.Browser",
      app.executableURL?.standardizedFileURL.path == expectedExecutable,
      app.isActive else { exit(121) }

let root = AXUIElementCreateApplication(pid)
guard (copied(root, kAXFrontmostAttribute as CFString) as? NSNumber)?.boolValue == true else { exit(122) }

print("pid_gate=PASS bundle_id_gate=PASS executable_gate=PASS active_gate=PASS frontmost_gate=PASS")
