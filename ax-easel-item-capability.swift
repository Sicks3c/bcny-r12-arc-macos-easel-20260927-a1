import Foundation
import AppKit
import ApplicationServices

struct ItemTuple {
    let window: AXUIElement
    let scroll: AXUIElement
    let grid: AXUIElement
    let image: AXUIElement
    let label: AXUIElement
}

struct Capability {
    let attributes: [String]
    let parameterized: [String]
    let actions: [String]
    let settable: [(String, Bool)]
}

struct Geometry {
    let position: CGPoint
    let size: CGSize
    let activation: CGPoint?

    var frame: CGRect {
        return CGRect(origin: position, size: size)
    }
}

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

func nodeAt(_ root: AXUIElement, _ indices: [Int]) -> AXUIElement? {
    var node = root
    for index in indices {
        let nodes = children(node)
        guard index >= 0 && index < nodes.count else { return nil }
        node = nodes[index]
    }
    return node
}

func isDescendant(_ candidate: AXUIElement, of ancestor: AXUIElement) -> Bool {
    return allNodes(ancestor).contains(where: { same($0, candidate) })
}

func actionNames(_ element: AXUIElement) -> [String]? {
    var raw: CFArray?
    let result = AXUIElementCopyActionNames(element, &raw)
    if result == .actionUnsupported || result == .attributeUnsupported {
        return []
    }
    guard result == .success, let names = raw as? [String] else { return nil }
    return names.sorted()
}

func attributeNames(_ element: AXUIElement) -> [String]? {
    var raw: CFArray?
    guard AXUIElementCopyAttributeNames(element, &raw) == .success,
          let names = raw as? [String] else { return nil }
    return names.sorted()
}

func parameterizedNames(_ element: AXUIElement) -> [String]? {
    var raw: CFArray?
    let result = AXUIElementCopyParameterizedAttributeNames(element, &raw)
    if result == .attributeUnsupported {
        return []
    }
    guard result == .success, let names = raw as? [String] else { return nil }
    return names.sorted()
}

func settable(_ element: AXUIElement, _ name: CFString) -> Bool? {
    var result = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, name, &result) == .success else { return nil }
    return result.boolValue
}

func capability(_ element: AXUIElement) -> Capability? {
    guard let attributes = attributeNames(element),
          let parameterized = parameterizedNames(element),
          let actions = actionNames(element) else { return nil }
    var settableRows: [(String, Bool)] = []
    for name in attributes {
        guard let value = settable(element, name as CFString) else { return nil }
        settableRows.append((name, value))
    }
    return Capability(attributes: attributes,
                      parameterized: parameterized,
                      actions: actions,
                      settable: settableRows)
}

func pointAttr(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let raw = copied(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return point
}

func sizeAttr(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let raw = copied(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return size
}

func geometry(_ element: AXUIElement, attributeNames: [String]) -> Geometry? {
    guard attributeNames.contains(kAXPositionAttribute as String),
          attributeNames.contains(kAXSizeAttribute as String),
          let position = pointAttr(element, kAXPositionAttribute as CFString),
          let size = sizeAttr(element, kAXSizeAttribute as CFString) else { return nil }
    let activationName = "AXActivationPoint"
    var activation: CGPoint?
    if attributeNames.contains(activationName) {
        guard let point = pointAttr(element, activationName as CFString) else { return nil }
        activation = point
    }
    return Geometry(position: position, size: size, activation: activation)
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

func same(_ left: AXUIElement, _ right: AXUIElement) -> Bool {
    return CFEqual(left, right)
}

func hasParent(_ element: AXUIElement, expected: AXUIElement) -> Bool {
    guard let raw = copied(element, kAXParentAttribute as CFString),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
    return CFEqual(raw, expected)
}

func hasWindow(_ element: AXUIElement, expected: AXUIElement) -> Bool {
    guard let raw = copied(element, kAXWindowAttribute as CFString),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
    return CFEqual(raw, expected)
}

func hasTopLevel(_ element: AXUIElement, expected: AXUIElement) -> Bool {
    guard let raw = copied(element, kAXTopLevelUIElementAttribute as CFString),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
    return CFEqual(raw, expected)
}

func hasPID(_ element: AXUIElement, expected: pid_t) -> Bool {
    var actual = pid_t(0)
    return AXUIElementGetPid(element, &actual) == .success && actual == expected
}

func exactSignOut(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "_NS:1753"
        && stringAttr(element, kAXTitleAttribute as CFString) == "Sign Out"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settable(element, kAXValueAttribute as CFString) == false
        && actionNames(element) == ["AXCancel", "AXPick", "AXPress"]
}

func exactMenuItem(_ element: AXUIElement, identifier: String, title: String) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXMenuItem"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == identifier
        && stringAttr(element, kAXTitleAttribute as CFString) == title
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settable(element, kAXValueAttribute as CFString) == false
        && actionNames(element) == ["AXCancel", "AXPick", "AXPress"]
}

func exactCanvas(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXLayoutArea"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXIdentifierAttribute as CFString) == "easelCanvasView"
}

func exactGrid(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXOpaqueProviderGroup"
        && stringAttr(element, kAXSubroleAttribute as CFString) == "AXOpaqueProviderGrid"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settable(element, kAXValueAttribute as CFString) == false
        && actionNames(element) == ["AXScrollToBottom", "AXScrollToTop"]
}

func exactImage(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXImage"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settable(element, kAXValueAttribute as CFString) == false
        && actionNames(element) == ["AXScrollToVisible"]
}

func exactLabel(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXStaticText"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settable(element, kAXValueAttribute as CFString) == false
        && actionNames(element) == ["AXScrollToVisible"]
}

func exactSearch(_ element: AXUIElement) -> Bool {
    return stringAttr(element, kAXRoleAttribute as CFString) == "AXTextField"
        && stringAttr(element, kAXSubroleAttribute as CFString) == ""
        && stringAttr(element, kAXPlaceholderValueAttribute as CFString) == "Search Easels…"
        && boolAttr(element, kAXEnabledAttribute as CFString) == true
        && settable(element, kAXValueAttribute as CFString) == true
        && actionNames(element) == ["AXConfirm", "AXShowMenu"]
}

func exactLibraryCandidate(_ element: AXUIElement) -> Bool {
    guard stringAttr(element, kAXRoleAttribute as CFString) == "AXGroup",
          stringAttr(element, kAXSubroleAttribute as CFString) == "AXHostingView" else { return false }
    let directChildren = children(element)
    let searches = directChildren.filter(exactSearch)
    let scrolls = directChildren.filter {
        stringAttr($0, kAXRoleAttribute as CFString) == "AXScrollArea"
            && stringAttr($0, kAXSubroleAttribute as CFString) == ""
    }
    guard searches.count == 1,
          scrolls.count == 1,
          children(scrolls[0]).count == 1,
          exactGrid(children(scrolls[0])[0]) else { return false }
    let gridChildren = children(children(scrolls[0])[0])
    return gridChildren.count == 2
        && exactImage(gridChildren[0])
        && exactLabel(gridChildren[1])
}

func resolveTuple(_ root: AXUIElement, expectedPID: pid_t) -> ItemTuple? {
    let nodes = allNodes(root)
    let windows = nodes.filter {
        stringAttr($0, kAXRoleAttribute as CFString) == "AXWindow"
            && stringAttr($0, kAXSubroleAttribute as CFString) == "AXStandardWindow"
    }
    guard windows.count == 1,
          let window = nodeAt(root, [0]),
          same(windows[0], window),
          boolAttr(window, kAXMainAttribute as CFString) == true,
          boolAttr(window, kAXFocusedAttribute as CFString) == true,
          hasPID(window, expected: expectedPID),
          nodes.filter({
              let role = stringAttr($0, kAXRoleAttribute as CFString)
              let subrole = stringAttr($0, kAXSubroleAttribute as CFString)
              return role == "AXSheet" || role == "AXPopover" || role == "AXDialog"
                  || subrole == "AXDialog" || subrole == "AXSystemDialog"
          }).isEmpty,
          let signOut = nodeAt(root, [1,1,0,15]),
          exactSignOut(signOut),
          nodes.filter(exactSignOut).count == 1,
          let closeLibrary = nodeAt(root, [1,9,0,13]),
          exactMenuItem(closeLibrary, identifier: "_NS:451", title: "Close Library"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:451", title: "Close Library") }).count == 1,
          let hideEasels = nodeAt(root, [1,9,0,15]),
          exactMenuItem(hideEasels, identifier: "_NS:1516", title: "Hide Easels"),
          nodes.filter({ exactMenuItem($0, identifier: "_NS:1516", title: "Hide Easels") }).count == 1,
          nodes.filter({ stringAttr($0, kAXRoleAttribute as CFString) == "AXTextField"
              && stringAttr($0, kAXSubroleAttribute as CFString) == "AXSecureTextField" }).isEmpty,
          let canvasScroll = nodeAt(root, [0,1]),
          stringAttr(canvasScroll, kAXRoleAttribute as CFString) == "AXScrollArea",
          stringAttr(canvasScroll, kAXSubroleAttribute as CFString) == "",
          let canvas = nodeAt(root, [0,1,0]),
          exactCanvas(canvas),
          nodes.filter(exactCanvas).count == 1,
          let library = nodeAt(root, [0,0]),
          exactLibraryCandidate(library),
          nodes.filter(exactLibraryCandidate).count == 1,
          !same(library, canvas),
          let search = nodeAt(root, [0,0,4]),
          exactSearch(search),
          nodes.filter(exactSearch).count == 1,
          let scroll = nodeAt(root, [0,0,13]),
          stringAttr(scroll, kAXRoleAttribute as CFString) == "AXScrollArea",
          stringAttr(scroll, kAXSubroleAttribute as CFString) == "",
          children(library).filter({ stringAttr($0, kAXRoleAttribute as CFString) == "AXScrollArea" }).count == 1,
          let grid = nodeAt(root, [0,0,13,0]),
          exactGrid(grid),
          nodes.filter(exactGrid).count == 1,
          let image = nodeAt(root, [0,0,13,0,0]),
          exactImage(image),
          nodes.filter(exactImage).count == 1,
          let label = nodeAt(root, [0,0,13,0,1]),
          exactLabel(label),
          children(scroll).count == 1,
          children(grid).count == 2,
          same(children(scroll)[0], grid),
          same(children(grid)[0], image),
          same(children(grid)[1], label),
          hasParent(library, expected: window),
          hasParent(canvasScroll, expected: window),
          hasParent(canvas, expected: canvasScroll),
          hasParent(search, expected: library),
          hasParent(scroll, expected: library),
          isDescendant(scroll, of: library),
          isDescendant(grid, of: library),
          isDescendant(image, of: library),
          isDescendant(label, of: library),
          !isDescendant(library, of: canvas),
          !isDescendant(scroll, of: canvas),
          !isDescendant(grid, of: canvas),
          !isDescendant(image, of: canvas),
          !isDescendant(label, of: canvas),
          hasParent(grid, expected: scroll),
          hasParent(image, expected: grid),
          hasParent(label, expected: grid),
          hasWindow(library, expected: window),
          hasWindow(canvasScroll, expected: window),
          hasWindow(canvas, expected: window),
          hasWindow(search, expected: window),
          hasWindow(scroll, expected: window),
          hasWindow(grid, expected: window),
          hasWindow(image, expected: window),
          hasWindow(label, expected: window),
          hasTopLevel(library, expected: window),
          hasTopLevel(canvasScroll, expected: window),
          hasTopLevel(canvas, expected: window),
          hasTopLevel(search, expected: window),
          hasTopLevel(scroll, expected: window),
          hasTopLevel(grid, expected: window),
          hasTopLevel(image, expected: window),
          hasTopLevel(label, expected: window),
          hasPID(library, expected: expectedPID),
          hasPID(canvasScroll, expected: expectedPID),
          hasPID(canvas, expected: expectedPID),
          hasPID(search, expected: expectedPID),
          hasPID(scroll, expected: expectedPID),
          hasPID(grid, expected: expectedPID),
          hasPID(image, expected: expectedPID),
          hasPID(label, expected: expectedPID) else { return nil }
    return ItemTuple(window: window, scroll: scroll, grid: grid, image: image, label: label)
}

func finite(_ rect: CGRect) -> Bool {
    return rect.origin.x.isFinite && rect.origin.y.isFinite
        && rect.size.width.isFinite && rect.size.height.isFinite
        && rect.size.width > 0 && rect.size.height > 0
}

func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.5) -> Bool {
    return finite(outer) && finite(inner)
        && inner.minX >= outer.minX - tolerance
        && inner.minY >= outer.minY - tolerance
        && inner.maxX <= outer.maxX + tolerance
        && inner.maxY <= outer.maxY + tolerance
}

func contains(_ rect: CGRect, _ point: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
    return point.x.isFinite && point.y.isFinite
        && point.x >= rect.minX - tolerance
        && point.y >= rect.minY - tolerance
        && point.x <= rect.maxX + tolerance
        && point.y <= rect.maxY + tolerance
}

func near(_ left: CGFloat, _ right: CGFloat) -> Bool {
    return abs(left - right) <= 1.0
}

func stable(_ left: Geometry, _ right: Geometry) -> Bool {
    guard near(left.position.x, right.position.x),
          near(left.position.y, right.position.y),
          near(left.size.width, right.size.width),
          near(left.size.height, right.size.height),
          (left.activation == nil) == (right.activation == nil) else { return false }
    if let first = left.activation, let second = right.activation {
        return near(first.x, second.x) && near(first.y, second.y)
    }
    return true
}

func matchingCGWindowBounds(pid: pid_t, axFrame: CGRect) -> [CGRect]? {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else { return nil }
    var matches: [CGRect] = []
    for row in raw {
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
        if near(bounds.origin.x, axFrame.origin.x)
            && near(bounds.origin.y, axFrame.origin.y)
            && near(bounds.size.width, axFrame.size.width)
            && near(bounds.size.height, axFrame.size.height) {
            matches.append(bounds)
        }
    }
    return matches
}

func oneActiveDisplayBounds() -> CGRect? {
    var count = UInt32(0)
    guard CGGetActiveDisplayList(0, nil, &count) == .success,
          count == 1 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var filled = UInt32(0)
    let result = displays.withUnsafeMutableBufferPointer { buffer in
        return CGGetActiveDisplayList(count, buffer.baseAddress, &filled)
    }
    guard result == .success,
          filled == 1,
          displays[0] == CGMainDisplayID() else { return nil }
    return CGDisplayBounds(displays[0])
}

func sanitized(_ value: CGFloat) -> String {
    return String(format: "%.1f", Double(value))
}

func printCapability(name: String, role: String, subrole: String,
                     capability: Capability, geometry: Geometry) {
    print("object=\(name) role=\(role) subrole=\(subrole) enabled=true owner_window_equal=true parent_relationship=true attribute_count=\(capability.attributes.count) parameterized_count=\(capability.parameterized.count) action_count=\(capability.actions.count)")
    for row in capability.settable {
        print("object=\(name) attribute=\(row.0) settable=\(row.1)")
    }
    for value in capability.parameterized {
        print("object=\(name) parameterized=\(value)")
    }
    for value in capability.actions {
        print("object=\(name) action=\(value)")
    }
    print("object=\(name) position_available=true size_available=true activation_available=\(geometry.activation != nil) position_x=\(sanitized(geometry.position.x)) position_y=\(sanitized(geometry.position.y)) size_width=\(sanitized(geometry.size.width)) size_height=\(sanitized(geometry.size.height))")
    if let point = geometry.activation {
        print("object=\(name) activation_x=\(sanitized(point.x)) activation_y=\(sanitized(point.y))")
    }
}

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else { exit(120) }
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path

guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(121) }
let root = AXUIElementCreateApplication(pid)
guard let tuple = resolveTuple(root, expectedPID: pid),
      let windowAttributes = attributeNames(tuple.window),
      let scrollAttributes = attributeNames(tuple.scroll),
      let gridCapability = capability(tuple.grid),
      let imageCapability = capability(tuple.image),
      let labelCapability = capability(tuple.label),
      let windowGeometry = geometry(tuple.window, attributeNames: windowAttributes),
      let scrollGeometry = geometry(tuple.scroll, attributeNames: scrollAttributes),
      let gridGeometry = geometry(tuple.grid, attributeNames: gridCapability.attributes),
      let imageGeometry = geometry(tuple.image, attributeNames: imageCapability.attributes),
      let labelGeometry = geometry(tuple.label, attributeNames: labelCapability.attributes) else { exit(122) }

guard let displayBounds = oneActiveDisplayBounds() else { exit(123) }
guard let cgWindowMatches = matchingCGWindowBounds(pid: pid, axFrame: windowGeometry.frame),
      cgWindowMatches.count == 1 else { exit(124) }

guard finite(windowGeometry.frame), finite(displayBounds),
      contains(displayBounds, windowGeometry.frame),
      contains(windowGeometry.frame, scrollGeometry.frame),
      contains(windowGeometry.frame, gridGeometry.frame),
      contains(windowGeometry.frame, imageGeometry.frame),
      contains(windowGeometry.frame, labelGeometry.frame),
      contains(displayBounds, scrollGeometry.frame),
      contains(displayBounds, gridGeometry.frame),
      contains(displayBounds, imageGeometry.frame),
      contains(displayBounds, labelGeometry.frame),
      contains(scrollGeometry.frame, gridGeometry.frame),
      contains(gridGeometry.frame, imageGeometry.frame),
      contains(gridGeometry.frame, labelGeometry.frame),
      scrollGeometry.activation.map({ contains(scrollGeometry.frame, $0) }) ?? true,
      gridGeometry.activation.map({ contains(gridGeometry.frame, $0) }) ?? true,
      imageGeometry.activation.map({ contains(imageGeometry.frame, $0) }) ?? true,
      labelGeometry.activation.map({ contains(labelGeometry.frame, $0) }) ?? true else { exit(125) }

Thread.sleep(forTimeInterval: 1.0)
guard processGate(pid, expectedExecutable: expectedExecutable) else { exit(126) }
let finalRoot = AXUIElementCreateApplication(pid)
guard let finalTuple = resolveTuple(finalRoot, expectedPID: pid),
      same(tuple.window, finalTuple.window),
      same(tuple.scroll, finalTuple.scroll),
      same(tuple.grid, finalTuple.grid),
      same(tuple.image, finalTuple.image),
      same(tuple.label, finalTuple.label),
      let finalWindowAttributes = attributeNames(finalTuple.window),
      let finalScrollAttributes = attributeNames(finalTuple.scroll),
      let finalGridAttributes = attributeNames(finalTuple.grid),
      let finalImageAttributes = attributeNames(finalTuple.image),
      let finalLabelAttributes = attributeNames(finalTuple.label),
      let finalWindowGeometry = geometry(finalTuple.window, attributeNames: finalWindowAttributes),
      let finalScrollGeometry = geometry(finalTuple.scroll, attributeNames: finalScrollAttributes),
      let finalGridGeometry = geometry(finalTuple.grid, attributeNames: finalGridAttributes),
      let finalImageGeometry = geometry(finalTuple.image, attributeNames: finalImageAttributes),
      let finalLabelGeometry = geometry(finalTuple.label, attributeNames: finalLabelAttributes),
      let finalDisplayBounds = oneActiveDisplayBounds(),
      near(displayBounds.origin.x, finalDisplayBounds.origin.x),
      near(displayBounds.origin.y, finalDisplayBounds.origin.y),
      near(displayBounds.size.width, finalDisplayBounds.size.width),
      near(displayBounds.size.height, finalDisplayBounds.size.height),
      stable(windowGeometry, finalWindowGeometry),
      stable(scrollGeometry, finalScrollGeometry),
      stable(gridGeometry, finalGridGeometry),
      stable(imageGeometry, finalImageGeometry),
      stable(labelGeometry, finalLabelGeometry),
      contains(finalDisplayBounds, finalWindowGeometry.frame),
      contains(finalWindowGeometry.frame, finalScrollGeometry.frame),
      contains(finalWindowGeometry.frame, finalGridGeometry.frame),
      contains(finalWindowGeometry.frame, finalImageGeometry.frame),
      contains(finalWindowGeometry.frame, finalLabelGeometry.frame),
      contains(finalDisplayBounds, finalScrollGeometry.frame),
      contains(finalDisplayBounds, finalGridGeometry.frame),
      contains(finalDisplayBounds, finalImageGeometry.frame),
      contains(finalDisplayBounds, finalLabelGeometry.frame),
      contains(finalScrollGeometry.frame, finalGridGeometry.frame),
      contains(finalGridGeometry.frame, finalImageGeometry.frame),
      contains(finalGridGeometry.frame, finalLabelGeometry.frame),
      finalScrollGeometry.activation.map({ contains(finalScrollGeometry.frame, $0) }) ?? true,
      finalGridGeometry.activation.map({ contains(finalGridGeometry.frame, $0) }) ?? true,
      finalImageGeometry.activation.map({ contains(finalImageGeometry.frame, $0) }) ?? true,
      finalLabelGeometry.activation.map({ contains(finalLabelGeometry.frame, $0) }) ?? true,
      let finalCGWindowMatches = matchingCGWindowBounds(pid: pid, axFrame: finalWindowGeometry.frame),
      finalCGWindowMatches.count == 1 else { exit(127) }

print("tuple=exact_one_item standard_windows=1 sign_out_exact=1 close_library_exact=1 hide_easels_exact=1 secure_login_fields=0 easel_canvas_exact=1 library_hosting_candidates=1 search_easels_exact=1 direct_scroll_areas=1 grids=1 matching_images=1 label_siblings=1 children_grid=2 children_scroll=1 library_descendant=true canvas_descendant=false")
print("geometry_snapshots=2 stable=true active_display_count=1 cg_window_bounds_matches=1 window_main=true window_focused=true sheets=0 dialogs=0 popovers=0")
print("window_x=\(sanitized(windowGeometry.position.x)) window_y=\(sanitized(windowGeometry.position.y)) window_width=\(sanitized(windowGeometry.size.width)) window_height=\(sanitized(windowGeometry.size.height))")
print("display_x=\(sanitized(displayBounds.origin.x)) display_y=\(sanitized(displayBounds.origin.y)) display_width=\(sanitized(displayBounds.size.width)) display_height=\(sanitized(displayBounds.size.height))")
print("scroll_x=\(sanitized(scrollGeometry.position.x)) scroll_y=\(sanitized(scrollGeometry.position.y)) scroll_width=\(sanitized(scrollGeometry.size.width)) scroll_height=\(sanitized(scrollGeometry.size.height))")
printCapability(name: "grid", role: "AXOpaqueProviderGroup", subrole: "AXOpaqueProviderGrid", capability: gridCapability, geometry: gridGeometry)
printCapability(name: "image", role: "AXImage", subrole: "", capability: imageCapability, geometry: imageGeometry)
printCapability(name: "label", role: "AXStaticText", subrole: "", capability: labelCapability, geometry: labelGeometry)
print("ax_value_reads=0 object_title_reads=0 object_identifier_reads=0 object_description_reads=0 object_help_reads=0 object_url_reads=0 clipboard_reads=0 dom_reads=0 route_reads=0 action_invocations=0 scroll_to_visible_invocations=0 show_menu_invocations=0 context_actions=0 right_clicks=0 delete_actions=0 new_easel_actions=0 content_actions=0 marker_actions=0 share_actions=0 confirm_actions=0 cancel_actions=0 sign_out_actions=0 screenshots=0")
