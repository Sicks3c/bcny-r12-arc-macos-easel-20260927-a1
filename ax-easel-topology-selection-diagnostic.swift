import Foundation
import AppKit
import ApplicationServices

private let output = FileHandle.standardOutput

func validKey(_ key: String) -> Bool {
    !key.isEmpty && key.unicodeScalars.allSatisfy {
        ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0.value == 95
    }
}

func validValue(_ value: String) -> Bool {
    if ["true", "false", "PASS", "FAIL", "SKIPPED"].contains(value) { return true }
    guard let parsed = Int(value), String(parsed) == value else { return false }
    return true
}

func emit(_ key: String, _ value: String) {
    guard validKey(key), validValue(value),
          let data = "\(key)=\(value)\n".data(using: .utf8) else { exit(118) }
    output.write(data)
    output.synchronizeFile()
}

func emitBool(_ key: String, _ value: Bool) { emit(key, value ? "true" : "false") }
func emitCount(_ key: String, _ value: Int) { emit(key, String(max(0, value))) }
func emitRC(_ key: String, _ value: AXError?) {
    if let value = value { emit(key, String(Int(value.rawValue))) }
    else { emit(key, "SKIPPED") }
}

struct CopyProbe {
    let rc: AXError
    let value: CFTypeRef?
}

func copyAttribute(_ element: AXUIElement, _ name: CFString) -> CopyProbe {
    var value: CFTypeRef?
    let rc = AXUIElementCopyAttributeValue(element, name, &value)
    return CopyProbe(rc: rc, value: value)
}

struct StringProbe {
    let rc: AXError
    let value: String?
}

func stringProbe(_ element: AXUIElement, _ name: CFString) -> StringProbe {
    let probe = copyAttribute(element, name)
    return StringProbe(rc: probe.rc, value: probe.rc == .success ? probe.value as? String : nil)
}

func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    stringProbe(element, name).value
}

func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
    let probe = copyAttribute(element, name)
    guard probe.rc == .success else { return nil }
    return (probe.value as? NSNumber)?.boolValue
}

struct ChildrenProbe {
    let rc: AXError
    let typeCorrect: Bool
    let children: [AXUIElement]
}

func copyChildren(_ element: AXUIElement) -> ChildrenProbe {
    let probe = copyAttribute(element, kAXChildrenAttribute as CFString)
    guard probe.rc == .success else {
        return ChildrenProbe(rc: probe.rc, typeCorrect: false, children: [])
    }
    guard let children = probe.value as? [AXUIElement] else {
        return ChildrenProbe(rc: probe.rc, typeCorrect: false, children: [])
    }
    return ChildrenProbe(rc: probe.rc, typeCorrect: true, children: children)
}

func same(_ left: AXUIElement, _ right: AXUIElement) -> Bool { CFEqual(left, right) }

struct SnapshotEntry {
    let element: AXUIElement
    let childrenProbe: ChildrenProbe
}

final class Snapshot {
    var entries: [SnapshotEntry] = []
    var depthTruncations = 0

    init(root: AXUIElement) { visit(root, depth: 0) }

    func visit(_ element: AXUIElement, depth: Int) {
        if entries.contains(where: { same($0.element, element) }) { return }
        guard depth <= 22 else { depthTruncations += 1; return }
        let probe = copyChildren(element)
        entries.append(SnapshotEntry(element: element, childrenProbe: probe))
        guard probe.rc == .success, probe.typeCorrect else { return }
        for child in probe.children { visit(child, depth: depth + 1) }
    }

    func entry(_ element: AXUIElement) -> SnapshotEntry? {
        entries.first(where: { same($0.element, element) })
    }

    func children(_ element: AXUIElement) -> [AXUIElement]? {
        guard let row = entry(element), row.childrenProbe.rc == .success,
              row.childrenProbe.typeCorrect else { return nil }
        return row.childrenProbe.children
    }

    func nodeAt(_ indices: [Int]) -> AXUIElement? {
        guard let root = entries.first?.element else { return nil }
        var node = root
        for index in indices {
            guard let children = children(node), index >= 0, index < children.count else { return nil }
            node = children[index]
        }
        return node
    }

    func descendants(of ancestor: AXUIElement) -> [AXUIElement]? {
        var result: [AXUIElement] = []
        var visited: [AXUIElement] = []
        func walk(_ element: AXUIElement) -> Bool {
            if visited.contains(where: { same($0, element) }) { return true }
            visited.append(element)
            guard let row = self.entry(element) else { return false }
            let children: [AXUIElement]
            if row.childrenProbe.rc == .success && row.childrenProbe.typeCorrect {
                children = row.childrenProbe.children
            } else if row.childrenProbe.rc == .noValue || row.childrenProbe.rc == .attributeUnsupported {
                children = []
            } else { return false }
            for child in children {
                result.append(child)
                if !walk(child) { return false }
            }
            return true
        }
        return walk(ancestor) ? result : nil
    }
}

struct NamesProbe {
    let rc: AXError
    let typeCorrect: Bool
    let names: [String]
}

func attributeNames(_ element: AXUIElement) -> NamesProbe {
    var raw: CFArray?
    let rc = AXUIElementCopyAttributeNames(element, &raw)
    guard rc == .success, let names = raw as? [String] else {
        return NamesProbe(rc: rc, typeCorrect: false, names: [])
    }
    return NamesProbe(rc: rc, typeCorrect: true, names: names)
}

struct ActionsProbe {
    let rc: AXError
    let typeCorrect: Bool
    let names: [String]
}

func actionNames(_ element: AXUIElement) -> ActionsProbe {
    var raw: CFArray?
    let rc = AXUIElementCopyActionNames(element, &raw)
    guard rc == .success, let names = raw as? [String] else {
        return ActionsProbe(rc: rc, typeCorrect: false, names: [])
    }
    return ActionsProbe(rc: rc, typeCorrect: true, names: names.sorted())
}

struct SettableProbe {
    let rc: AXError
    let value: Bool
}

func settable(_ element: AXUIElement, _ name: CFString) -> SettableProbe {
    var value = DarwinBoolean(false)
    let rc = AXUIElementIsAttributeSettable(element, name, &value)
    return SettableProbe(rc: rc, value: value.boolValue)
}

func blankSubrole(_ element: AXUIElement) -> Bool {
    let probe = stringProbe(element, kAXSubroleAttribute as CFString)
    return (probe.rc == .noValue || probe.rc == .attributeUnsupported)
        || (probe.rc == .success && (probe.value == nil || probe.value == ""))
}

func roleIs(_ element: AXUIElement, _ role: String, _ subrole: String) -> Bool {
    guard stringAttribute(element, kAXRoleAttribute as CFString) == role else { return false }
    return subrole.isEmpty ? blankSubrole(element)
        : stringAttribute(element, kAXSubroleAttribute as CFString) == subrole
}

func exactActions(_ element: AXUIElement, _ expected: [String]) -> Bool {
    let probe = actionNames(element)
    return probe.rc == .success && probe.typeCorrect && probe.names == expected.sorted()
}

func exactValueSettable(_ element: AXUIElement, _ expected: Bool) -> Bool {
    let probe = settable(element, kAXValueAttribute as CFString)
    return probe.rc == .success && probe.value == expected
}

func exactGrid(_ element: AXUIElement) -> Bool {
    roleIs(element, "AXOpaqueProviderGroup", "AXOpaqueProviderGrid")
        && boolAttribute(element, kAXEnabledAttribute as CFString) == true
        && exactValueSettable(element, false)
        && exactActions(element, ["AXScrollToBottom", "AXScrollToTop"])
}

func exactImage(_ element: AXUIElement) -> Bool {
    roleIs(element, "AXImage", "")
        && boolAttribute(element, kAXEnabledAttribute as CFString) == true
        && exactValueSettable(element, false)
        && exactActions(element, ["AXScrollToVisible"])
}

func exactLabel(_ element: AXUIElement) -> Bool {
    roleIs(element, "AXStaticText", "")
        && boolAttribute(element, kAXEnabledAttribute as CFString) == true
        && exactValueSettable(element, false)
        && exactActions(element, ["AXScrollToVisible"])
}

func exactSearch(_ element: AXUIElement) -> Bool {
    roleIs(element, "AXTextField", "")
        && stringAttribute(element, kAXPlaceholderValueAttribute as CFString) == "Search Easels…"
        && boolAttribute(element, kAXEnabledAttribute as CFString) == true
        && exactValueSettable(element, true)
        && exactActions(element, ["AXConfirm", "AXShowMenu"])
}

func exactCanvas(_ element: AXUIElement) -> Bool {
    roleIs(element, "AXLayoutArea", "")
        && stringAttribute(element, kAXIdentifierAttribute as CFString) == "easelCanvasView"
}

struct MenuComponents {
    let present: Bool
    let role: Bool
    let subrole: Bool
    let identifier: Bool
    let title: Bool
    let enabled: Bool
    let valueSettable: Bool
    let actions: Bool
    var exact: Bool { present && role && subrole && identifier && title && enabled && valueSettable && actions }
}

func menuComponents(_ element: AXUIElement?, identifier: String, title: String) -> MenuComponents {
    guard let element = element else {
        return MenuComponents(present: false, role: false, subrole: false, identifier: false,
                              title: false, enabled: false, valueSettable: false, actions: false)
    }
    return MenuComponents(
        present: true,
        role: stringAttribute(element, kAXRoleAttribute as CFString) == "AXMenuItem",
        subrole: blankSubrole(element),
        identifier: stringAttribute(element, kAXIdentifierAttribute as CFString) == identifier,
        title: stringAttribute(element, kAXTitleAttribute as CFString) == title,
        enabled: boolAttribute(element, kAXEnabledAttribute as CFString) == true,
        valueSettable: exactValueSettable(element, false),
        actions: exactActions(element, ["AXCancel", "AXPick", "AXPress"])
    )
}

func exactMenuItem(_ element: AXUIElement, identifier: String, title: String) -> Bool {
    menuComponents(element, identifier: identifier, title: title).exact
}

func exactLibraryCandidate(_ snapshot: Snapshot, _ element: AXUIElement) -> Bool {
    guard roleIs(element, "AXGroup", "AXHostingView"),
          let direct = snapshot.children(element) else { return false }
    let searches = direct.filter(exactSearch)
    let scrolls = direct.filter { roleIs($0, "AXScrollArea", "") }
    guard searches.count == 1, scrolls.count == 1,
          let scrollChildren = snapshot.children(scrolls[0]), scrollChildren.count == 1,
          exactGrid(scrollChildren[0]),
          let gridChildren = snapshot.children(scrollChildren[0]), gridChildren.count == 2 else { return false }
    return exactImage(gridChildren[0]) && exactLabel(gridChildren[1])
}

struct ElementRelation {
    let rc: AXError
    let typeCorrect: Bool
    let equal: Bool
}

func elementRelation(_ element: AXUIElement, _ attribute: CFString, _ expected: AXUIElement) -> ElementRelation {
    let probe = copyAttribute(element, attribute)
    guard probe.rc == .success, let value = probe.value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return ElementRelation(rc: probe.rc, typeCorrect: false, equal: false)
    }
    return ElementRelation(rc: probe.rc, typeCorrect: true, equal: CFEqual(value, expected))
}

struct PIDProbe { let rc: AXError; let equal: Bool }

func pidProbe(_ element: AXUIElement, expected: pid_t) -> PIDProbe {
    var actual = pid_t(0)
    let rc = AXUIElementGetPid(element, &actual)
    return PIDProbe(rc: rc, equal: rc == .success && actual == expected)
}

struct ItemNodes {
    let window: AXUIElement
    let library: AXUIElement
    let search: AXUIElement
    let scroll: AXUIElement
    let grid: AXUIElement
    let image: AXUIElement
    let label: AXUIElement
    let canvasScroll: AXUIElement
    let canvas: AXUIElement
}

struct CanvasComponents {
    let present: Bool
    let role: Bool
    let subrole: Bool
    let identifier: Bool
    var exact: Bool { present && role && subrole && identifier }
}

struct Topology {
    let nodes: ItemNodes?
    let windowCount: Int
    let candidateCount: Int
    let gridCount: Int
    let imageCount: Int
    let labelCount: Int
    let canvasCount: Int
    let signOutCount: Int
    let closeCount: Int
    let hideCount: Int
    let canvas: CanvasComponents
    let signOut: MenuComponents
    let close: MenuComponents
    let hide: MenuComponents
    let windowUnique: Bool
    let candidateUnique: Bool
    let gridUnique: Bool
    let imageUnique: Bool
    let labelUnique: Bool
    let canvasUnique: Bool
    let windowEqual: Bool
    let candidateEqual: Bool
    let gridEqual: Bool
    let imageEqual: Bool
    let labelEqual: Bool
    let canvasEqual: Bool
    let corePathReady: Bool
    let uniquenessReady: Bool
    let fixedIdentityReady: Bool
    let menuPathsReady: Bool
    let windowMain: Bool
    let windowFocused: Bool
    let modalCount: Int
    let secureFieldCount: Int
    let parentChain: Bool
    let parentErrors: [AXError]
    let pidEquality: Bool
    let pidErrors: [AXError]
    let candidateDescendantOfCanvas: Bool?
    let fixedChildErrors: [AXError]
    let depthReady: Bool
    let topologyReady: Bool
}

func resolveTopology(_ snapshot: Snapshot, pid: pid_t) -> Topology {
    let all = snapshot.entries.map { $0.element }
    let windows = all.filter { roleIs($0, "AXWindow", "AXStandardWindow") }
    let candidates = all.filter { exactLibraryCandidate(snapshot, $0) }
    let grids = all.filter(exactGrid)
    let images = all.filter(exactImage)
    let labels = all.filter(exactLabel)
    let canvases = all.filter(exactCanvas)
    let signOuts = all.filter { exactMenuItem($0, identifier: "_NS:1753", title: "Sign Out") }
    let closes = all.filter { exactMenuItem($0, identifier: "_NS:451", title: "Close Library") }
    let hides = all.filter { exactMenuItem($0, identifier: "_NS:1516", title: "Hide Easels") }
    let modals = all.filter {
        let role = stringAttribute($0, kAXRoleAttribute as CFString)
        let subrole = stringAttribute($0, kAXSubroleAttribute as CFString)
        return role == "AXSheet" || role == "AXPopover" || role == "AXDialog"
            || subrole == "AXDialog" || subrole == "AXSystemDialog"
    }
    let secureFields = all.filter { roleIs($0, "AXTextField", "AXSecureTextField") }

    let raw = [snapshot.nodeAt([0]), snapshot.nodeAt([0,0]), snapshot.nodeAt([0,0,4]),
               snapshot.nodeAt([0,0,13]), snapshot.nodeAt([0,0,13,0]),
               snapshot.nodeAt([0,0,13,0,0]), snapshot.nodeAt([0,0,13,0,1]),
               snapshot.nodeAt([0,1]), snapshot.nodeAt([0,1,0])]
    let nodes: ItemNodes? = raw.allSatisfy { $0 != nil }
        ? ItemNodes(window: raw[0]!, library: raw[1]!, search: raw[2]!, scroll: raw[3]!,
                    grid: raw[4]!, image: raw[5]!, label: raw[6]!, canvasScroll: raw[7]!, canvas: raw[8]!)
        : nil

    let fixedCanvas = nodes?.canvas
    let canvasComponents = CanvasComponents(
        present: fixedCanvas != nil,
        role: fixedCanvas.map { stringAttribute($0, kAXRoleAttribute as CFString) == "AXLayoutArea" } ?? false,
        subrole: fixedCanvas.map(blankSubrole) ?? false,
        identifier: fixedCanvas.map {
            stringAttribute($0, kAXIdentifierAttribute as CFString) == "easelCanvasView"
        } ?? false
    )
    let signOut = menuComponents(snapshot.nodeAt([1,1,0,15]), identifier: "_NS:1753", title: "Sign Out")
    let close = menuComponents(snapshot.nodeAt([1,9,0,13]), identifier: "_NS:451", title: "Close Library")
    let hide = menuComponents(snapshot.nodeAt([1,9,0,15]), identifier: "_NS:1516", title: "Hide Easels")

    let windowUnique = windows.count == 1
    let candidateUnique = candidates.count == 1
    let gridUnique = grids.count == 1
    let imageUnique = images.count == 1
    let labelUnique = labels.count == 1
    let canvasUnique = canvases.count == 1
    let windowEqual = nodes.map { windowUnique && same(windows[0], $0.window) } ?? false
    let candidateEqual = nodes.map { candidateUnique && same(candidates[0], $0.library) } ?? false
    let gridEqual = nodes.map { gridUnique && same(grids[0], $0.grid) } ?? false
    let imageEqual = nodes.map { imageUnique && same(images[0], $0.image) } ?? false
    let labelEqual = nodes.map { labelUnique && same(labels[0], $0.label) } ?? false
    let canvasEqual = nodes.map { canvasUnique && same(canvases[0], $0.canvas) } ?? false

    var corePath = false
    var main = false
    var focused = false
    var parentChain = false
    var parentErrors: [AXError] = []
    var pidEquality = false
    var pidErrors: [AXError] = []
    var descendant: Bool?
    var fixedChildErrors: [AXError] = []
    if let nodes = nodes {
        main = boolAttribute(nodes.window, kAXMainAttribute as CFString) == true
        focused = boolAttribute(nodes.window, kAXFocusedAttribute as CFString) == true
        corePath = roleIs(nodes.window, "AXWindow", "AXStandardWindow")
            && roleIs(nodes.library, "AXGroup", "AXHostingView")
            && exactSearch(nodes.search) && roleIs(nodes.scroll, "AXScrollArea", "")
            && exactGrid(nodes.grid) && exactImage(nodes.image) && exactLabel(nodes.label)
            && roleIs(nodes.canvasScroll, "AXScrollArea", "") && canvasComponents.exact

        let parentChecks = [
            elementRelation(nodes.library, kAXParentAttribute as CFString, nodes.window),
            elementRelation(nodes.search, kAXParentAttribute as CFString, nodes.library),
            elementRelation(nodes.scroll, kAXParentAttribute as CFString, nodes.library),
            elementRelation(nodes.grid, kAXParentAttribute as CFString, nodes.scroll),
            elementRelation(nodes.image, kAXParentAttribute as CFString, nodes.grid),
            elementRelation(nodes.label, kAXParentAttribute as CFString, nodes.grid),
            elementRelation(nodes.canvasScroll, kAXParentAttribute as CFString, nodes.window),
            elementRelation(nodes.canvas, kAXParentAttribute as CFString, nodes.canvasScroll)
        ]
        parentErrors = parentChecks.filter { $0.rc != .success || !$0.typeCorrect }.map { $0.rc }
        parentChain = parentChecks.allSatisfy { $0.rc == .success && $0.typeCorrect && $0.equal }

        let pidChecks = [nodes.window, nodes.library, nodes.search, nodes.scroll, nodes.grid,
                         nodes.image, nodes.label, nodes.canvasScroll, nodes.canvas].map {
            pidProbe($0, expected: pid)
        }
        pidErrors = pidChecks.filter { $0.rc != .success }.map { $0.rc }
        pidEquality = pidChecks.allSatisfy { $0.rc == .success && $0.equal }

        if let descendants = snapshot.descendants(of: nodes.canvas) {
            descendant = descendants.contains { same($0, nodes.library) || same($0, nodes.grid) }
        } else if parentChain { descendant = false }

        let fixedContainers = [snapshot.entries.first?.element, snapshot.nodeAt([0]),
                               snapshot.nodeAt([0,0]), snapshot.nodeAt([0,0,13]),
                               snapshot.nodeAt([0,0,13,0]), snapshot.nodeAt([0,1]),
                               snapshot.nodeAt([1]), snapshot.nodeAt([1,1]),
                               snapshot.nodeAt([1,1,0]), snapshot.nodeAt([1,9]),
                               snapshot.nodeAt([1,9,0])].compactMap { $0 }
        fixedChildErrors = fixedContainers.compactMap { element in
            guard let row = snapshot.entry(element) else { return .invalidUIElement }
            return (row.childrenProbe.rc == .success && row.childrenProbe.typeCorrect)
                ? nil : row.childrenProbe.rc
        }
    }

    let uniqueness = windowUnique && candidateUnique && gridUnique && imageUnique && labelUnique
        && canvasUnique && signOuts.count == 1 && closes.count == 1 && hides.count == 1
    let identity = windowEqual && candidateEqual && gridEqual && imageEqual && labelEqual && canvasEqual
    let menus = signOut.exact && close.exact && hide.exact
    let depthReady = snapshot.depthTruncations == 0
    let ready = corePath && uniqueness && identity && menus && main && focused && modals.isEmpty
        && secureFields.isEmpty && parentChain && pidEquality && descendant == false
        && fixedChildErrors.isEmpty && depthReady

    return Topology(nodes: nodes, windowCount: windows.count, candidateCount: candidates.count,
                    gridCount: grids.count, imageCount: images.count, labelCount: labels.count,
                    canvasCount: canvases.count, signOutCount: signOuts.count,
                    closeCount: closes.count, hideCount: hides.count,
                    canvas: canvasComponents, signOut: signOut, close: close, hide: hide,
                    windowUnique: windowUnique, candidateUnique: candidateUnique,
                    gridUnique: gridUnique, imageUnique: imageUnique, labelUnique: labelUnique,
                    canvasUnique: canvasUnique, windowEqual: windowEqual,
                    candidateEqual: candidateEqual, gridEqual: gridEqual, imageEqual: imageEqual,
                    labelEqual: labelEqual, canvasEqual: canvasEqual, corePathReady: corePath,
                    uniquenessReady: uniqueness, fixedIdentityReady: identity,
                    menuPathsReady: menus, windowMain: main, windowFocused: focused,
                    modalCount: modals.count, secureFieldCount: secureFields.count,
                    parentChain: parentChain, parentErrors: parentErrors,
                    pidEquality: pidEquality, pidErrors: pidErrors,
                    candidateDescendantOfCanvas: descendant, fixedChildErrors: fixedChildErrors,
                    depthReady: depthReady, topologyReady: ready)
}

func emitMenu(_ prefix: String, _ menu: MenuComponents) {
    emitBool("\(prefix)_path_present", menu.present)
    emitBool("\(prefix)_role_exact", menu.role)
    emitBool("\(prefix)_subrole_exact", menu.subrole)
    emitBool("\(prefix)_identifier_exact", menu.identifier)
    emitBool("\(prefix)_title_exact", menu.title)
    emitBool("\(prefix)_enabled_exact", menu.enabled)
    emitBool("\(prefix)_value_settable_exact", menu.valueSettable)
    emitBool("\(prefix)_actions_exact", menu.actions)
    emitBool("\(prefix)_tuple_exact", menu.exact)
}

func emitTopology(_ prefix: String, _ topology: Topology) {
    emitCount("\(prefix)_standard_window_count", topology.windowCount)
    emitCount("\(prefix)_library_candidate_count", topology.candidateCount)
    emitCount("\(prefix)_grid_count", topology.gridCount)
    emitCount("\(prefix)_image_count", topology.imageCount)
    emitCount("\(prefix)_label_count", topology.labelCount)
    emitCount("\(prefix)_canvas_count", topology.canvasCount)
    emitCount("\(prefix)_sign_out_count", topology.signOutCount)
    emitCount("\(prefix)_close_library_count", topology.closeCount)
    emitCount("\(prefix)_hide_easels_count", topology.hideCount)
    emitBool("\(prefix)_canvas_path_present", topology.canvas.present)
    emitBool("\(prefix)_canvas_role_exact", topology.canvas.role)
    emitBool("\(prefix)_canvas_subrole_exact", topology.canvas.subrole)
    emitBool("\(prefix)_canvas_identifier_exact", topology.canvas.identifier)
    emitBool("\(prefix)_canvas_tuple_exact", topology.canvas.exact)
    emitMenu("\(prefix)_menu_sign_out", topology.signOut)
    emitMenu("\(prefix)_menu_close_library", topology.close)
    emitMenu("\(prefix)_menu_hide_easels", topology.hide)
    emitBool("\(prefix)_window_unique", topology.windowUnique)
    emitBool("\(prefix)_candidate_unique", topology.candidateUnique)
    emitBool("\(prefix)_grid_unique", topology.gridUnique)
    emitBool("\(prefix)_image_unique", topology.imageUnique)
    emitBool("\(prefix)_label_unique", topology.labelUnique)
    emitBool("\(prefix)_canvas_unique", topology.canvasUnique)
    emitBool("\(prefix)_window_fixed_equal", topology.windowEqual)
    emitBool("\(prefix)_candidate_fixed_equal", topology.candidateEqual)
    emitBool("\(prefix)_grid_fixed_equal", topology.gridEqual)
    emitBool("\(prefix)_image_fixed_equal", topology.imageEqual)
    emitBool("\(prefix)_label_fixed_equal", topology.labelEqual)
    emitBool("\(prefix)_canvas_fixed_equal", topology.canvasEqual)
    emitBool("\(prefix)_core_path_ready", topology.corePathReady)
    emitBool("\(prefix)_uniqueness_ready", topology.uniquenessReady)
    emitBool("\(prefix)_fixed_identity_ready", topology.fixedIdentityReady)
    emitBool("\(prefix)_menu_paths_ready", topology.menuPathsReady)
    emitBool("\(prefix)_window_main", topology.windowMain)
    emitBool("\(prefix)_window_focused", topology.windowFocused)
    emitCount("\(prefix)_sheet_dialog_popover_count", topology.modalCount)
    emitCount("\(prefix)_secure_login_field_count", topology.secureFieldCount)
    emitBool("\(prefix)_parent_chain_ready", topology.parentChain)
    emitCount("\(prefix)_parent_error_count", topology.parentErrors.count)
    emitRC("\(prefix)_parent_first_error_rc", topology.parentErrors.first)
    emitBool("\(prefix)_pid_equality_ready", topology.pidEquality)
    emitCount("\(prefix)_pid_error_count", topology.pidErrors.count)
    emitRC("\(prefix)_pid_first_error_rc", topology.pidErrors.first)
    if let descendant = topology.candidateDescendantOfCanvas {
        emitBool("\(prefix)_candidate_descendant_of_canvas", descendant)
    } else { emit("\(prefix)_candidate_descendant_of_canvas", "SKIPPED") }
    emitCount("\(prefix)_fixed_child_error_count", topology.fixedChildErrors.count)
    emitRC("\(prefix)_fixed_child_first_error_rc", topology.fixedChildErrors.first)
    emitBool("\(prefix)_depth_ready", topology.depthReady)
    emitBool("\(prefix)_topology_ready", topology.topologyReady)
}

struct SelectionProbe {
    let advertised: Bool
    let rc: AXError?
    let settableValue: Bool?
}

let selectionAttributes: [(String, CFString)] = [
    ("selected", kAXSelectedAttribute as CFString),
    ("focused", kAXFocusedAttribute as CFString),
    ("selected_children", kAXSelectedChildrenAttribute as CFString),
    ("selected_rows", kAXSelectedRowsAttribute as CFString),
    ("selected_columns", kAXSelectedColumnsAttribute as CFString),
    ("selected_cells", kAXSelectedCellsAttribute as CFString)
]

func selectionProbes(_ element: AXUIElement?) -> (NamesProbe?, [String: SelectionProbe]) {
    guard let element = element else { return (nil, [:]) }
    let names = attributeNames(element)
    var probes: [String: SelectionProbe] = [:]
    for (key, attribute) in selectionAttributes {
        let advertised = names.rc == .success && names.typeCorrect && names.names.contains(attribute as String)
        let settableProbe = settable(element, attribute)
        probes[key] = SelectionProbe(advertised: advertised, rc: settableProbe.rc,
                                     settableValue: settableProbe.rc == .success ? settableProbe.value : nil)
    }
    return (names, probes)
}

func emitSelections(_ prefix: String, _ element: AXUIElement?) -> [String: SelectionProbe] {
    let result = selectionProbes(element)
    emitRC("\(prefix)_attribute_names_rc", result.0?.rc)
    emitCount("\(prefix)_attribute_names_count", result.0?.names.count ?? 0)
    emitBool("\(prefix)_attribute_names_type_correct", result.0?.typeCorrect ?? false)
    for (key, _) in selectionAttributes {
        let probe = result.1[key]
        emitBool("\(prefix)_\(key)_advertised", probe?.advertised ?? false)
        emitRC("\(prefix)_\(key)_settable_rc", probe?.rc)
        if let settableValue = probe?.settableValue {
            emitBool("\(prefix)_\(key)_settable", settableValue)
        } else { emit("\(prefix)_\(key)_settable", "SKIPPED") }
    }
    return result.1
}

func semanticSelectionCount(_ rows: [String: [String: SelectionProbe]]) -> Int {
    rows.values.reduce(0) { total, probes in
        total + ["selected", "selected_children", "selected_rows", "selected_columns", "selected_cells"].filter {
            probes[$0]?.advertised == true && probes[$0]?.rc == .success
                && probes[$0]?.settableValue == true
        }.count
    }
}

func focusCount(_ rows: [String: [String: SelectionProbe]]) -> Int {
    rows.values.filter {
        $0["focused"]?.advertised == true && $0["focused"]?.rc == .success
            && $0["focused"]?.settableValue == true
    }.count
}

func probesStable(_ first: [String: [String: SelectionProbe]],
                  _ second: [String: [String: SelectionProbe]]) -> Bool {
    for node in ["grid", "image", "label"] {
        for (attribute, _) in selectionAttributes {
            guard let left = first[node]?[attribute], let right = second[node]?[attribute],
                  left.advertised == right.advertised,
                  left.rc?.rawValue == right.rc?.rawValue,
                  left.settableValue == right.settableValue else { return false }
        }
    }
    return true
}

func processGate(_ pid: pid_t, expectedExecutable: String) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          app.bundleIdentifier == "company.thebrowser.Browser",
          app.executableURL?.standardizedFileURL.path == expectedExecutable,
          app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    let frontmost = copyAttribute(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString)
    return frontmost.rc == .success && (frontmost.value as? NSNumber)?.boolValue == true
}

emitCount("diagnostic_schema", 2)
emitBool("declared_no_perform_action_calls", true)
emitBool("declared_no_set_attribute_calls", true)
emitBool("declared_no_selection_value_reads", true)
emitBool("declared_no_event_post_calls", true)
emitBool("declared_no_hit_test_calls", true)
emitBool("declared_no_parameterized_value_calls", true)
emitBool("declared_no_screenshot_calls", true)
emitBool("declared_no_pasteboard_calls", true)
emitCount("easel_item_title_reads", 0)
emitCount("easel_item_static_content_reads", 0)
emitCount("easel_item_description_reads", 0)
emitCount("easel_item_help_reads", 0)
emitCount("easel_web_url_attribute_reads", 0)
emitCount("easel_route_reads", 0)
emitBool("known_chrome_title_gates_enabled", true)
emitBool("known_search_placeholder_gate_enabled", true)

guard CommandLine.arguments.count == 3, let parsedPID = Int32(CommandLine.arguments[1]),
      AXIsProcessTrusted() else {
    emit("process_gate", "FAIL"); emitBool("diagnostic_complete", false); exit(120)
}
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
guard processGate(pid, expectedExecutable: expectedExecutable) else {
    emit("process_gate", "FAIL"); emitBool("diagnostic_complete", false); exit(121)
}
emit("process_gate", "PASS")

let firstSnapshot = Snapshot(root: AXUIElementCreateApplication(pid))
let firstTopology = resolveTopology(firstSnapshot, pid: pid)
emitTopology("snapshot1", firstTopology)
var firstSelections: [String: [String: SelectionProbe]] = [:]
firstSelections["grid"] = emitSelections("snapshot1_grid", firstTopology.nodes?.grid)
firstSelections["image"] = emitSelections("snapshot1_image", firstTopology.nodes?.image)
firstSelections["label"] = emitSelections("snapshot1_label", firstTopology.nodes?.label)
let firstSemanticCount = semanticSelectionCount(firstSelections)
let firstFocusCount = focusCount(firstSelections)
emitCount("snapshot1_semantic_selection_candidate_count", firstSemanticCount)
emitCount("snapshot1_focus_candidate_count", firstFocusCount)

Thread.sleep(forTimeInterval: 1.0)
let secondProcessGate = processGate(pid, expectedExecutable: expectedExecutable)
emit("snapshot2_process_gate", secondProcessGate ? "PASS" : "FAIL")
let secondSnapshot = Snapshot(root: AXUIElementCreateApplication(pid))
let secondTopology = resolveTopology(secondSnapshot, pid: pid)
emitTopology("snapshot2", secondTopology)
var secondSelections: [String: [String: SelectionProbe]] = [:]
secondSelections["grid"] = emitSelections("snapshot2_grid", secondTopology.nodes?.grid)
secondSelections["image"] = emitSelections("snapshot2_image", secondTopology.nodes?.image)
secondSelections["label"] = emitSelections("snapshot2_label", secondTopology.nodes?.label)
let secondSemanticCount = semanticSelectionCount(secondSelections)
let secondFocusCount = focusCount(secondSelections)
emitCount("snapshot2_semantic_selection_candidate_count", secondSemanticCount)
emitCount("snapshot2_focus_candidate_count", secondFocusCount)

let selectionStable = probesStable(firstSelections, secondSelections)
let selectionReady = firstTopology.topologyReady && secondTopology.topologyReady
    && secondProcessGate && selectionStable && firstSemanticCount > 0 && secondSemanticCount > 0
emitBool("selection_probe_stable", selectionStable)
emitBool("selection_capability_ready", selectionReady)
emitBool("diagnostic_complete", true)
