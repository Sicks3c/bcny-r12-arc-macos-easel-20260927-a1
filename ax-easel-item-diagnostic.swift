import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

private let output = FileHandle.standardOutput
private var geometryAXValueDecodeCount = 0

func validKey(_ key: String) -> Bool {
    guard !key.isEmpty else { return false }
    return key.unicodeScalars.allSatisfy {
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
          let data = "\(key)=\(value)\n".data(using: .utf8) else { exit(119) }
    output.write(data)
    output.synchronizeFile()
}

func emitBool(_ key: String, _ value: Bool) { emit(key, value ? "true" : "false") }
func emitCount(_ key: String, _ value: Int) { emit(key, String(max(0, value))) }
func emitRC(_ key: String, _ value: Int) { emit(key, String(value)) }
func emitOptionalRC(_ key: String, _ value: Int?) {
    if let value = value { emitRC(key, value) } else { emit(key, "SKIPPED") }
}
func emitOptionalBool(_ key: String, _ value: Bool?) {
    if let value = value { emitBool(key, value) } else { emit(key, "SKIPPED") }
}
func status(_ value: Bool?) -> String {
    guard let value = value else { return "SKIPPED" }
    return value ? "PASS" : "FAIL"
}

func rcInt(_ error: AXError) -> Int { Int(error.rawValue) }

struct CopyProbe {
    let rc: AXError
    let value: CFTypeRef?
}

func copyAttribute(_ element: AXUIElement, _ name: CFString) -> CopyProbe {
    var value: CFTypeRef?
    let rc = AXUIElementCopyAttributeValue(element, name, &value)
    return CopyProbe(rc: rc, value: value)
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

    init(root: AXUIElement) {
        visit(root, depth: 0)
    }

    func visit(_ element: AXUIElement, depth: Int) {
        if entries.contains(where: { same($0.element, element) }) { return }
        guard depth <= 22 else {
            depthTruncations += 1
            return
        }
        let probe = copyChildren(element)
        entries.append(SnapshotEntry(element: element, childrenProbe: probe))
        guard probe.rc == .success, probe.typeCorrect else { return }
        for child in probe.children { visit(child, depth: depth + 1) }
    }

    func entry(_ element: AXUIElement) -> SnapshotEntry? {
        entries.first(where: { same($0.element, element) })
    }

    func children(_ element: AXUIElement) -> [AXUIElement]? {
        guard let entry = entry(element),
              entry.childrenProbe.rc == .success,
              entry.childrenProbe.typeCorrect else { return nil }
        return entry.childrenProbe.children
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
            guard let entry = self.entry(element) else { return false }
            let children: [AXUIElement]
            if entry.childrenProbe.rc == .success && entry.childrenProbe.typeCorrect {
                children = entry.childrenProbe.children
            } else if entry.childrenProbe.rc == .noValue || entry.childrenProbe.rc == .attributeUnsupported {
                children = []
            } else {
                return false
            }
            for child in children {
                result.append(child)
                if !walk(child) { return false }
            }
            return true
        }
        return walk(ancestor) ? result : nil
    }

    var childCopyErrorCodes: [Int] {
        entries.compactMap {
            let rc = rcInt($0.childrenProbe.rc)
            return (rc == 0 && $0.childrenProbe.typeCorrect) ? nil : rc
        }
    }
}

func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    let probe = copyAttribute(element, name)
    guard probe.rc == .success else { return nil }
    return probe.value as? String
}

func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
    let probe = copyAttribute(element, name)
    guard probe.rc == .success else { return nil }
    return (probe.value as? NSNumber)?.boolValue
}

func roleIs(_ element: AXUIElement, _ role: String, _ subrole: String) -> Bool {
    guard stringAttribute(element, kAXRoleAttribute as CFString) == role else { return false }
    let actualSubrole = stringAttribute(element, kAXSubroleAttribute as CFString)
    return subrole.isEmpty ? (actualSubrole == nil || actualSubrole == "") : actualSubrole == subrole
}

func identifierIs(_ element: AXUIElement, _ identifier: String) -> Bool {
    stringAttribute(element, kAXIdentifierAttribute as CFString) == identifier
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

struct ActionProbe {
    let rc: AXError
    let typeCorrect: Bool
    let names: [String]
}

func actionNames(_ element: AXUIElement) -> ActionProbe {
    var raw: CFArray?
    let rc = AXUIElementCopyActionNames(element, &raw)
    guard rc == .success, let names = raw as? [String] else {
        return ActionProbe(rc: rc, typeCorrect: false, names: [])
    }
    return ActionProbe(rc: rc, typeCorrect: true, names: names.sorted())
}

struct SettableProbe {
    let rc: AXError
    let value: Bool
}

func settable(_ element: AXUIElement, _ name: CFString) -> SettableProbe {
    var result = DarwinBoolean(false)
    let rc = AXUIElementIsAttributeSettable(element, name, &result)
    return SettableProbe(rc: rc, value: result.boolValue)
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
    roleIs(element, "AXLayoutArea", "") && identifierIs(element, "easelCanvasView")
}

func exactMenuItem(_ element: AXUIElement, identifier: String, title: String) -> Bool {
    roleIs(element, "AXMenuItem", "")
        && identifierIs(element, identifier)
        && stringAttribute(element, kAXTitleAttribute as CFString) == title
        && boolAttribute(element, kAXEnabledAttribute as CFString) == true
        && exactValueSettable(element, false)
        && exactActions(element, ["AXCancel", "AXPick", "AXPress"])
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
    let equal: Bool?
}

func elementRelation(_ element: AXUIElement, attribute: CFString, expected: AXUIElement) -> ElementRelation {
    let probe = copyAttribute(element, attribute)
    guard probe.rc == .success else {
        return ElementRelation(rc: probe.rc, typeCorrect: false, equal: nil)
    }
    guard let value = probe.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return ElementRelation(rc: probe.rc, typeCorrect: false, equal: false)
    }
    return ElementRelation(rc: probe.rc, typeCorrect: true, equal: CFEqual(value, expected))
}

struct PIDProbe {
    let rc: AXError
    let equal: Bool
}

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

struct TopologyResult {
    let nodes: ItemNodes?
    let standardWindowCount: Int
    let libraryCandidateCount: Int
    let gridCount: Int
    let imageCount: Int
    let labelCount: Int
    let canvasCount: Int
    let signOutCount: Int
    let closeLibraryCount: Int
    let hideEaselsCount: Int
    let dialogCount: Int
    let secureFieldCount: Int
    let windowMain: Bool
    let windowFocused: Bool
    let fixedPathChildErrorCodes: [Int]
    let parentChain: Bool
    let parentErrorCodes: [Int]
    let pidEquality: Bool
    let pidErrorCodes: [Int]
    let canvasDescendant: Bool?
    let topologyReady: Bool
}

func resolveTopology(_ snapshot: Snapshot, pid: pid_t) -> TopologyResult {
    let all = snapshot.entries.map { $0.element }
    let windows = all.filter { roleIs($0, "AXWindow", "AXStandardWindow") }
    let candidates = all.filter { exactLibraryCandidate(snapshot, $0) }
    let grids = all.filter(exactGrid)
    let images = all.filter(exactImage)
    let labels = all.filter(exactLabel)
    let canvases = all.filter(exactCanvas)
    let signOutItems = all.filter { exactMenuItem($0, identifier: "_NS:1753", title: "Sign Out") }
    let closeLibraryItems = all.filter { exactMenuItem($0, identifier: "_NS:451", title: "Close Library") }
    let hideEaselsItems = all.filter { exactMenuItem($0, identifier: "_NS:1516", title: "Hide Easels") }
    let dialogs = all.filter {
        let role = stringAttribute($0, kAXRoleAttribute as CFString)
        let subrole = stringAttribute($0, kAXSubroleAttribute as CFString)
        return role == "AXSheet" || role == "AXPopover" || role == "AXDialog"
            || subrole == "AXDialog" || subrole == "AXSystemDialog"
    }
    let secureFields = all.filter { roleIs($0, "AXTextField", "AXSecureTextField") }

    let rawPaths = [
        snapshot.nodeAt([0]), snapshot.nodeAt([0,0]), snapshot.nodeAt([0,0,4]),
        snapshot.nodeAt([0,0,13]), snapshot.nodeAt([0,0,13,0]),
        snapshot.nodeAt([0,0,13,0,0]), snapshot.nodeAt([0,0,13,0,1]),
        snapshot.nodeAt([0,1]), snapshot.nodeAt([0,1,0])
    ]
    var nodes: ItemNodes?
    if rawPaths.allSatisfy({ $0 != nil }) {
        nodes = ItemNodes(window: rawPaths[0]!, library: rawPaths[1]!, search: rawPaths[2]!,
                          scroll: rawPaths[3]!, grid: rawPaths[4]!, image: rawPaths[5]!,
                          label: rawPaths[6]!, canvasScroll: rawPaths[7]!, canvas: rawPaths[8]!)
    }

    var parentChain = false
    var parentErrors: [Int] = []
    var pidEquality = false
    var pidErrors: [Int] = []
    var canvasDescendant: Bool?
    var corePath = false
    var windowMain = false
    var windowFocused = false
    var fixedPathChildErrors: [Int] = []

    if let nodes = nodes {
        windowMain = boolAttribute(nodes.window, kAXMainAttribute as CFString) == true
        windowFocused = boolAttribute(nodes.window, kAXFocusedAttribute as CFString) == true
        corePath = roleIs(nodes.window, "AXWindow", "AXStandardWindow")
            && roleIs(nodes.library, "AXGroup", "AXHostingView")
            && exactSearch(nodes.search)
            && roleIs(nodes.scroll, "AXScrollArea", "")
            && exactGrid(nodes.grid) && exactImage(nodes.image) && exactLabel(nodes.label)
            && roleIs(nodes.canvasScroll, "AXScrollArea", "") && exactCanvas(nodes.canvas)

        let parentChecks = [
            elementRelation(nodes.library, attribute: kAXParentAttribute as CFString, expected: nodes.window),
            elementRelation(nodes.search, attribute: kAXParentAttribute as CFString, expected: nodes.library),
            elementRelation(nodes.scroll, attribute: kAXParentAttribute as CFString, expected: nodes.library),
            elementRelation(nodes.grid, attribute: kAXParentAttribute as CFString, expected: nodes.scroll),
            elementRelation(nodes.image, attribute: kAXParentAttribute as CFString, expected: nodes.grid),
            elementRelation(nodes.label, attribute: kAXParentAttribute as CFString, expected: nodes.grid),
            elementRelation(nodes.canvasScroll, attribute: kAXParentAttribute as CFString, expected: nodes.window),
            elementRelation(nodes.canvas, attribute: kAXParentAttribute as CFString, expected: nodes.canvasScroll)
        ]
        parentErrors = parentChecks.filter { $0.rc != .success || !$0.typeCorrect }.map { rcInt($0.rc) }
        parentChain = parentChecks.allSatisfy { $0.rc == .success && $0.typeCorrect && $0.equal == true }

        let pidChecks = [nodes.window, nodes.library, nodes.search, nodes.scroll, nodes.grid,
                         nodes.image, nodes.label, nodes.canvasScroll, nodes.canvas].map {
            pidProbe($0, expected: pid)
        }
        pidErrors = pidChecks.filter { $0.rc != .success }.map { rcInt($0.rc) }
        pidEquality = pidChecks.allSatisfy { $0.rc == .success && $0.equal }

        if let canvasDescendants = snapshot.descendants(of: nodes.canvas) {
            canvasDescendant = canvasDescendants.contains(where: { same($0, nodes.library) || same($0, nodes.grid) })
        } else if parentChain {
            canvasDescendant = false
        }

        let fixedContainers = [
            snapshot.entries.first?.element, snapshot.nodeAt([0]), snapshot.nodeAt([0,0]),
            snapshot.nodeAt([0,0,13]), snapshot.nodeAt([0,0,13,0]), snapshot.nodeAt([0,1]),
            snapshot.nodeAt([1]), snapshot.nodeAt([1,1]), snapshot.nodeAt([1,1,0]),
            snapshot.nodeAt([1,9]), snapshot.nodeAt([1,9,0])
        ].compactMap { $0 }
        fixedPathChildErrors = fixedContainers.compactMap { element in
            guard let entry = snapshot.entry(element) else { return -25202 }
            return (entry.childrenProbe.rc == .success && entry.childrenProbe.typeCorrect)
                ? nil : rcInt(entry.childrenProbe.rc)
        }
    }

    let uniqueness = windows.count == 1 && candidates.count == 1 && grids.count == 1
        && images.count == 1 && labels.count == 1 && canvases.count == 1
        && signOutItems.count == 1 && closeLibraryItems.count == 1 && hideEaselsItems.count == 1
    let fixedIdentity = nodes.map { nodes in
        windows.count == 1 && same(windows[0], nodes.window)
            && candidates.count == 1 && same(candidates[0], nodes.library)
            && grids.count == 1 && same(grids[0], nodes.grid)
            && images.count == 1 && same(images[0], nodes.image)
            && labels.count == 1 && same(labels[0], nodes.label)
            && canvases.count == 1 && same(canvases[0], nodes.canvas)
    } ?? false
    let menuPathsReady = snapshot.nodeAt([1,1,0,15]).map {
        exactMenuItem($0, identifier: "_NS:1753", title: "Sign Out")
    } == true && snapshot.nodeAt([1,9,0,13]).map {
        exactMenuItem($0, identifier: "_NS:451", title: "Close Library")
    } == true && snapshot.nodeAt([1,9,0,15]).map {
        exactMenuItem($0, identifier: "_NS:1516", title: "Hide Easels")
    } == true
    let topologyReady = corePath && uniqueness && fixedIdentity && menuPathsReady
        && windowMain && windowFocused && dialogs.isEmpty
        && secureFields.isEmpty && parentChain && pidEquality && canvasDescendant == false
        && fixedPathChildErrors.isEmpty && snapshot.depthTruncations == 0

    return TopologyResult(nodes: nodes, standardWindowCount: windows.count,
                          libraryCandidateCount: candidates.count, gridCount: grids.count,
                          imageCount: images.count, labelCount: labels.count,
                          canvasCount: canvases.count, signOutCount: signOutItems.count,
                          closeLibraryCount: closeLibraryItems.count,
                          hideEaselsCount: hideEaselsItems.count, dialogCount: dialogs.count,
                          secureFieldCount: secureFields.count, windowMain: windowMain,
                          windowFocused: windowFocused,
                          fixedPathChildErrorCodes: fixedPathChildErrors, parentChain: parentChain,
                          parentErrorCodes: parentErrors, pidEquality: pidEquality,
                          pidErrorCodes: pidErrors, canvasDescendant: canvasDescendant,
                          topologyReady: topologyReady)
}

let knownAXCodes: [(String, Int)] = [
    ("success", 0), ("failure", -25200), ("illegal_argument", -25201),
    ("invalid_ui_element", -25202), ("invalid_ui_element_observer", -25203),
    ("cannot_complete", -25204), ("attribute_unsupported", -25205),
    ("action_unsupported", -25206), ("notification_unsupported", -25207),
    ("not_implemented", -25208), ("notification_already_registered", -25209),
    ("notification_not_registered", -25210), ("api_disabled", -25211),
    ("no_value", -25212), ("parameterized_attribute_unsupported", -25213),
    ("not_enough_precision", -25214)
]

func emitErrorSummary(_ prefix: String, _ codes: [Int]) {
    emitCount("\(prefix)_error_count", codes.count)
    emitOptionalRC("\(prefix)_first_error_rc", codes.first)
    for (name, code) in knownAXCodes {
        emitCount("\(prefix)_rc_\(name)_count", codes.filter { $0 == code }.count)
    }
    emitCount("\(prefix)_rc_other_count", codes.filter { code in
        !knownAXCodes.contains(where: { $0.1 == code })
    }.count)
}

struct ParameterizedProbe {
    let rc: AXError
    let typeCorrect: Bool
    let count: Int
    let normalizedUnsupported: Bool
    let ready: Bool
}

func parameterizedNames(_ element: AXUIElement) -> ParameterizedProbe {
    var raw: CFArray?
    let rc = AXUIElementCopyParameterizedAttributeNames(element, &raw)
    if rc == .attributeUnsupported || rc == .parameterizedAttributeUnsupported {
        return ParameterizedProbe(rc: rc, typeCorrect: true, count: 0,
                                  normalizedUnsupported: true, ready: true)
    }
    guard rc == .success, let names = raw as? [String] else {
        return ParameterizedProbe(rc: rc, typeCorrect: false, count: 0,
                                  normalizedUnsupported: false, ready: false)
    }
    return ParameterizedProbe(rc: rc, typeCorrect: true, count: names.count,
                              normalizedUnsupported: false, ready: true)
}

struct SettableEnumeration {
    let finished: Bool
    let total: Int
    let success: Int
    let errors: [Int]
}

func enumerateSettable(_ element: AXUIElement, names: NamesProbe) -> SettableEnumeration {
    guard names.rc == .success, names.typeCorrect else {
        return SettableEnumeration(finished: false, total: 0, success: 0, errors: [])
    }
    var success = 0
    var errors: [Int] = []
    for name in names.names {
        let probe = settable(element, name as CFString)
        if probe.rc == .success { success += 1 } else { errors.append(rcInt(probe.rc)) }
    }
    return SettableEnumeration(finished: true, total: names.names.count,
                               success: success, errors: errors)
}

func emitCapability(_ prefix: String, element: AXUIElement?) -> Bool {
    guard let element = element else {
        emitBool("probe_attributes_\(prefix)_finished", false)
        emit("attributes_\(prefix)_rc", "SKIPPED")
        emitCount("attributes_\(prefix)_count", 0)
        emitBool("attributes_\(prefix)_type_correct", false)
        emitBool("probe_actions_\(prefix)_finished", false)
        emit("actions_\(prefix)_rc", "SKIPPED")
        emitCount("actions_\(prefix)_count", 0)
        emitBool("actions_\(prefix)_expected", false)
        emitBool("probe_parameterized_\(prefix)_finished", false)
        emit("parameterized_\(prefix)_rc", "SKIPPED")
        emitCount("parameterized_\(prefix)_count", 0)
        emitBool("parameterized_\(prefix)_type_correct", false)
        emitBool("parameterized_\(prefix)_unsupported_normalized", false)
        emitBool("probe_settable_\(prefix)_finished", false)
        emitCount("settable_\(prefix)_total", 0)
        emitCount("settable_\(prefix)_success", 0)
        emitErrorSummary("settable_\(prefix)", [])
        emit("value_settable_\(prefix)_rc", "SKIPPED")
        emit("value_settable_\(prefix)", "SKIPPED")
        return false
    }

    let attributes = attributeNames(element)
    emitBool("probe_attributes_\(prefix)_finished", true)
    emitRC("attributes_\(prefix)_rc", rcInt(attributes.rc))
    emitCount("attributes_\(prefix)_count", attributes.names.count)
    emitBool("attributes_\(prefix)_type_correct", attributes.typeCorrect)

    let actions = actionNames(element)
    let expected: [String]
    if prefix == "grid" { expected = ["AXScrollToBottom", "AXScrollToTop"] }
    else { expected = ["AXScrollToVisible"] }
    let actionsExpected = actions.rc == .success && actions.typeCorrect && actions.names == expected.sorted()
    emitBool("probe_actions_\(prefix)_finished", true)
    emitRC("actions_\(prefix)_rc", rcInt(actions.rc))
    emitCount("actions_\(prefix)_count", actions.names.count)
    emitBool("actions_\(prefix)_expected", actionsExpected)

    let parameterized = parameterizedNames(element)
    emitBool("probe_parameterized_\(prefix)_finished", true)
    emitRC("parameterized_\(prefix)_rc", rcInt(parameterized.rc))
    emitCount("parameterized_\(prefix)_count", parameterized.count)
    emitBool("parameterized_\(prefix)_type_correct", parameterized.typeCorrect)
    emitBool("parameterized_\(prefix)_unsupported_normalized", parameterized.normalizedUnsupported)

    let enumeration = enumerateSettable(element, names: attributes)
    emitBool("probe_settable_\(prefix)_finished", enumeration.finished)
    emitCount("settable_\(prefix)_total", enumeration.total)
    emitCount("settable_\(prefix)_success", enumeration.success)
    emitErrorSummary("settable_\(prefix)", enumeration.errors)

    let valueSettable = settable(element, kAXValueAttribute as CFString)
    emitRC("value_settable_\(prefix)_rc", rcInt(valueSettable.rc))
    if valueSettable.rc == .success { emitBool("value_settable_\(prefix)", valueSettable.value) }
    else { emit("value_settable_\(prefix)", "SKIPPED") }

    return attributes.rc == .success && attributes.typeCorrect && actionsExpected
        && parameterized.ready && enumeration.finished
        && valueSettable.rc == .success && !valueSettable.value
}

func emitRelation(_ prefix: String, element: AXUIElement?, expected: AXUIElement?, attribute: CFString) -> Bool {
    guard let element = element, let expected = expected else {
        emit("\(prefix)_rc", "SKIPPED")
        emit("\(prefix)_equal", "SKIPPED")
        emitBool("\(prefix)_unsupported_normalized", false)
        return false
    }
    let relation = elementRelation(element, attribute: attribute, expected: expected)
    emitRC("\(prefix)_rc", rcInt(relation.rc))
    let normalizedUnsupported = relation.rc == .noValue
        || relation.rc == .attributeUnsupported
        || relation.rc == .parameterizedAttributeUnsupported
    emitBool("\(prefix)_unsupported_normalized", normalizedUnsupported)
    if relation.rc == .success {
        emit("\(prefix)_equal", status(relation.equal))
        return relation.typeCorrect && relation.equal == true
    }
    emit("\(prefix)_equal", "SKIPPED")
    return normalizedUnsupported
}

struct PointProbe {
    let advertised: Bool?
    let rc: AXError?
    let typeCorrect: Bool?
    let finite: Bool?
    let point: CGPoint?
}

struct SizeProbe {
    let advertised: Bool?
    let rc: AXError?
    let typeCorrect: Bool?
    let finite: Bool?
    let positive: Bool?
    let size: CGSize?
}

func pointProbe(_ element: AXUIElement?, names: NamesProbe?, attributeName: String) -> PointProbe {
    guard let element = element, let names = names,
          names.rc == .success, names.typeCorrect else {
        return PointProbe(advertised: nil, rc: nil, typeCorrect: nil, finite: nil, point: nil)
    }
    guard names.names.contains(attributeName) else {
        return PointProbe(advertised: false, rc: nil, typeCorrect: nil, finite: nil, point: nil)
    }
    let copied = copyAttribute(element, attributeName as CFString)
    guard copied.rc == .success else {
        return PointProbe(advertised: true, rc: copied.rc, typeCorrect: nil, finite: nil, point: nil)
    }
    guard let raw = copied.value, CFGetTypeID(raw) == AXValueGetTypeID() else {
        return PointProbe(advertised: true, rc: copied.rc, typeCorrect: false, finite: nil, point: nil)
    }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgPoint else {
        return PointProbe(advertised: true, rc: copied.rc, typeCorrect: false, finite: nil, point: nil)
    }
    var point = CGPoint.zero
    geometryAXValueDecodeCount += 1
    guard AXValueGetValue(value, .cgPoint, &point) else {
        return PointProbe(advertised: true, rc: copied.rc, typeCorrect: false, finite: nil, point: nil)
    }
    let finite = point.x.isFinite && point.y.isFinite
    return PointProbe(advertised: true, rc: copied.rc, typeCorrect: true, finite: finite,
                      point: finite ? point : nil)
}

func sizeProbe(_ element: AXUIElement?, names: NamesProbe?) -> SizeProbe {
    guard let element = element, let names = names,
          names.rc == .success, names.typeCorrect else {
        return SizeProbe(advertised: nil, rc: nil, typeCorrect: nil, finite: nil, positive: nil, size: nil)
    }
    let name = kAXSizeAttribute as String
    guard names.names.contains(name) else {
        return SizeProbe(advertised: false, rc: nil, typeCorrect: nil, finite: nil, positive: nil, size: nil)
    }
    let copied = copyAttribute(element, kAXSizeAttribute as CFString)
    guard copied.rc == .success else {
        return SizeProbe(advertised: true, rc: copied.rc, typeCorrect: nil, finite: nil, positive: nil, size: nil)
    }
    guard let raw = copied.value, CFGetTypeID(raw) == AXValueGetTypeID() else {
        return SizeProbe(advertised: true, rc: copied.rc, typeCorrect: false, finite: nil, positive: nil, size: nil)
    }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgSize else {
        return SizeProbe(advertised: true, rc: copied.rc, typeCorrect: false, finite: nil, positive: nil, size: nil)
    }
    var size = CGSize.zero
    geometryAXValueDecodeCount += 1
    guard AXValueGetValue(value, .cgSize, &size) else {
        return SizeProbe(advertised: true, rc: copied.rc, typeCorrect: false, finite: nil, positive: nil, size: nil)
    }
    let finite = size.width.isFinite && size.height.isFinite
    let positive = finite && size.width > 0 && size.height > 0
    return SizeProbe(advertised: true, rc: copied.rc, typeCorrect: true, finite: finite,
                     positive: positive, size: positive ? size : nil)
}

func emitPoint(_ prefix: String, _ probe: PointProbe) {
    emitOptionalBool("\(prefix)_advertised", probe.advertised)
    emitOptionalRC("\(prefix)_copy_rc", probe.rc.map(rcInt))
    emitOptionalBool("\(prefix)_type_correct", probe.typeCorrect)
    emitOptionalBool("\(prefix)_finite", probe.finite)
    emit("\(prefix)_positive", "SKIPPED")
}

func emitSize(_ prefix: String, _ probe: SizeProbe) {
    emitOptionalBool("\(prefix)_advertised", probe.advertised)
    emitOptionalRC("\(prefix)_copy_rc", probe.rc.map(rcInt))
    emitOptionalBool("\(prefix)_type_correct", probe.typeCorrect)
    emitOptionalBool("\(prefix)_finite", probe.finite)
    emitOptionalBool("\(prefix)_positive", probe.positive)
}

struct FrameProbe {
    let position: PointProbe
    let size: SizeProbe
    var frame: CGRect? {
        guard let point = position.point, let size = size.size else { return nil }
        return CGRect(origin: point, size: size)
    }
    var ready: Bool { frame != nil }
}

func frameProbe(_ element: AXUIElement?, names: NamesProbe?) -> FrameProbe {
    FrameProbe(position: pointProbe(element, names: names, attributeName: kAXPositionAttribute as String),
               size: sizeProbe(element, names: names))
}

func finite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite
        && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
}

func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.5) -> Bool {
    finite(outer) && finite(inner) && inner.minX >= outer.minX - tolerance
        && inner.minY >= outer.minY - tolerance && inner.maxX <= outer.maxX + tolerance
        && inner.maxY <= outer.maxY + tolerance
}

func contains(_ rect: CGRect, _ point: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
    finite(rect) && point.x.isFinite && point.y.isFinite
        && point.x >= rect.minX - tolerance && point.y >= rect.minY - tolerance
        && point.x <= rect.maxX + tolerance && point.y <= rect.maxY + tolerance
}

struct ActivationProbe {
    let advertised: Bool?
    let rc: AXError?
    let state: String
    let typeCorrect: Bool?
    let finite: Bool?
    let inFrame: Bool?
    let ready: Bool
}

func activationProbe(_ element: AXUIElement?, names: NamesProbe?, frame: CGRect?) -> ActivationProbe {
    let point = pointProbe(element, names: names, attributeName: "AXActivationPoint")
    guard let advertised = point.advertised else {
        return ActivationProbe(advertised: nil, rc: nil, state: "SKIPPED", typeCorrect: nil,
                               finite: nil, inFrame: nil, ready: false)
    }
    if !advertised {
        return ActivationProbe(advertised: false, rc: nil, state: "SKIPPED", typeCorrect: nil,
                               finite: nil, inFrame: nil, ready: true)
    }
    if let rc = point.rc, rc == .noValue || rc == .attributeUnsupported
        || rc == .parameterizedAttributeUnsupported {
        return ActivationProbe(advertised: true, rc: rc, state: "SKIPPED", typeCorrect: nil,
                               finite: nil, inFrame: nil, ready: true)
    }
    guard point.rc == .success else {
        return ActivationProbe(advertised: true, rc: point.rc, state: "FAIL", typeCorrect: nil,
                               finite: nil, inFrame: nil, ready: false)
    }
    let inFrame = point.point.flatMap { p in frame.map { contains($0, p) } }
    let ready = point.typeCorrect == true && point.finite == true && inFrame == true
    return ActivationProbe(advertised: true, rc: point.rc, state: ready ? "PASS" : "FAIL",
                           typeCorrect: point.typeCorrect, finite: point.finite,
                           inFrame: inFrame, ready: ready)
}

func emitActivation(_ prefix: String, _ probe: ActivationProbe) {
    emitOptionalBool("activation_\(prefix)_advertised", probe.advertised)
    emitOptionalRC("activation_\(prefix)_copy_rc", probe.rc.map(rcInt))
    emit("activation_\(prefix)_state", probe.state)
    emitOptionalBool("activation_\(prefix)_type_correct", probe.typeCorrect)
    emitOptionalBool("activation_\(prefix)_finite", probe.finite)
    emitOptionalBool("activation_\(prefix)_in_frame", probe.inFrame)
}

struct DisplayProbe {
    let rc: CGError
    let count: Int
    let mainOnly: Bool
    let bounds: CGRect?
}

func displayProbe() -> DisplayProbe {
    var count = UInt32(0)
    let first = CGGetActiveDisplayList(0, nil, &count)
    guard first == .success else { return DisplayProbe(rc: first, count: 0, mainOnly: false, bounds: nil) }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var filled = UInt32(0)
    let second = displays.withUnsafeMutableBufferPointer {
        CGGetActiveDisplayList(count, $0.baseAddress, &filled)
    }
    guard second == .success else { return DisplayProbe(rc: second, count: Int(filled), mainOnly: false, bounds: nil) }
    let mainOnly = filled == 1 && displays.first == CGMainDisplayID()
    return DisplayProbe(rc: second, count: Int(filled), mainOnly: mainOnly,
                        bounds: mainOnly ? CGDisplayBounds(displays[0]) : nil)
}

func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) <= 1.0 }

func cgWindowMatchCount(pid: pid_t, frame: CGRect?) -> Int? {
    guard let frame = frame,
          let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    return rows.filter { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let dictionary = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
        return near(bounds.origin.x, frame.origin.x) && near(bounds.origin.y, frame.origin.y)
            && near(bounds.size.width, frame.size.width) && near(bounds.size.height, frame.size.height)
    }.count
}

func stable(_ first: PointProbe, _ second: PointProbe) -> Bool? {
    guard let left = first.point, let right = second.point else { return nil }
    return near(left.x, right.x) && near(left.y, right.y)
}

func stable(_ first: SizeProbe, _ second: SizeProbe) -> Bool? {
    guard let left = first.size, let right = second.size else { return nil }
    return near(left.width, right.width) && near(left.height, right.height)
}

func processGate(_ pid: pid_t, expectedExecutable: String) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          app.bundleIdentifier == "company.thebrowser.Browser",
          app.executableURL?.standardizedFileURL.path == expectedExecutable,
          app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    let frontmost = copyAttribute(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString)
    return frontmost.rc == .success && (frontmost.value as? NSNumber)?.boolValue == true
}

emitCount("diagnostic_schema", 1)
emitBool("declared_no_perform_action_calls", true)
emitBool("declared_no_set_attribute_calls", true)
emitBool("declared_no_hit_test_calls", true)
emitBool("declared_no_parameterized_value_calls", true)
emitBool("declared_no_event_post_calls", true)
emitBool("declared_no_screenshot_calls", true)
emitBool("declared_no_pasteboard_calls", true)
emitCount("kaxvalue_attribute_reads", 0)
emitCount("easel_item_title_reads", 0)
emitCount("easel_item_static_content_reads", 0)
emitBool("known_chrome_title_gates_enabled", true)
emitBool("known_search_placeholder_gate_enabled", true)
emitCount("easel_item_description_reads", 0)
emitCount("easel_item_help_reads", 0)
emitCount("easel_web_url_attribute_reads", 0)
emitCount("easel_route_reads", 0)

guard CommandLine.arguments.count == 3,
      let parsedPID = Int32(CommandLine.arguments[1]), AXIsProcessTrusted() else {
    emit("process_gate", "FAIL")
    emitBool("diagnostic_complete", false)
    exit(120)
}
let pid = pid_t(parsedPID)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
guard processGate(pid, expectedExecutable: expectedExecutable) else {
    emit("process_gate", "FAIL")
    emitBool("diagnostic_complete", false)
    exit(121)
}
emit("process_gate", "PASS")

emitBool("probe_topology_started", true)
let root = AXUIElementCreateApplication(pid)
let firstSnapshot = Snapshot(root: root)
let topology = resolveTopology(firstSnapshot, pid: pid)
emitCount("standard_window_count", topology.standardWindowCount)
emitCount("library_candidate_count", topology.libraryCandidateCount)
emitCount("grid_count", topology.gridCount)
emitCount("image_count", topology.imageCount)
emitCount("label_count", topology.labelCount)
emitBool("grid_role_subrole_expected", topology.nodes.map {
    roleIs($0.grid, "AXOpaqueProviderGroup", "AXOpaqueProviderGrid")
} ?? false)
emitBool("image_role_subrole_expected", topology.nodes.map { roleIs($0.image, "AXImage", "") } ?? false)
emitBool("label_role_subrole_expected", topology.nodes.map { roleIs($0.label, "AXStaticText", "") } ?? false)
emitBool("grid_enabled_expected", topology.nodes.map {
    boolAttribute($0.grid, kAXEnabledAttribute as CFString) == true
} ?? false)
emitBool("image_enabled_expected", topology.nodes.map {
    boolAttribute($0.image, kAXEnabledAttribute as CFString) == true
} ?? false)
emitBool("label_enabled_expected", topology.nodes.map {
    boolAttribute($0.label, kAXEnabledAttribute as CFString) == true
} ?? false)
emitCount("canvas_count", topology.canvasCount)
emitCount("sign_out_count", topology.signOutCount)
emitCount("close_library_count", topology.closeLibraryCount)
emitCount("hide_easels_count", topology.hideEaselsCount)
emitCount("sheet_dialog_popover_count", topology.dialogCount)
emitCount("secure_login_field_count", topology.secureFieldCount)
emitBool("window_main", topology.windowMain)
emitBool("window_focused", topology.windowFocused)
emit("parent_chain_to_window", status(topology.parentChain))
emitErrorSummary("parent_chain", topology.parentErrorCodes)
emit("pid_equality_all", status(topology.pidEquality))
emitErrorSummary("pid_query", topology.pidErrorCodes)
emit("candidate_descendant_of_canvas", topology.canvasDescendant.map { $0 ? "true" : "false" } ?? "SKIPPED")
emitCount("traversal_depth_truncation_count", firstSnapshot.depthTruncations)
emitCount("child_copy_type_error_count", firstSnapshot.entries.filter {
    $0.childrenProbe.rc == .success && !$0.childrenProbe.typeCorrect
}.count)
emitErrorSummary("child_copy", firstSnapshot.childCopyErrorCodes)
emitErrorSummary("fixed_path_child_copy", topology.fixedPathChildErrorCodes)
emitBool("topology_ready", topology.topologyReady)
emitBool("probe_topology_finished", true)

let grid = topology.nodes?.grid
let image = topology.nodes?.image
let label = topology.nodes?.label
let gridCapability = emitCapability("grid", element: grid)
let imageCapability = emitCapability("image", element: image)
let labelCapability = emitCapability("label", element: label)
emitBool("parameterized_unsupported_normalization_supported", true)
emitBool("settable_query_count_emitted", true)
emitBool("settable_success_count_emitted", true)
emitBool("settable_error_histogram_emitted", true)

emitBool("probe_window_relation_started", true)
var relationReady = true
let relationNodes: [(String, AXUIElement?)] = [
    ("library", topology.nodes?.library), ("search", topology.nodes?.search),
    ("scroll", topology.nodes?.scroll),
    ("grid", grid), ("image", image), ("label", label),
    ("canvas_scroll", topology.nodes?.canvasScroll), ("canvas", topology.nodes?.canvas)
]
for (name, element) in relationNodes {
    relationReady = emitRelation("window_relation_\(name)", element: element,
                                 expected: topology.nodes?.window,
                                 attribute: kAXWindowAttribute as CFString) && relationReady
    relationReady = emitRelation("top_level_relation_\(name)", element: element,
                                 expected: topology.nodes?.window,
                                 attribute: kAXTopLevelUIElementAttribute as CFString) && relationReady
}
emitBool("probe_window_relation_finished", true)

let geometryNodes: [(String, AXUIElement?)] = [
    ("window", topology.nodes?.window), ("scroll", topology.nodes?.scroll),
    ("grid", grid), ("image", image), ("label", label)
]
var firstNames: [String: NamesProbe] = [:]
var firstFrames: [String: FrameProbe] = [:]
for (name, element) in geometryNodes {
    let names = element.map(attributeNames)
    if let names = names { firstNames[name] = names }
    let frame = frameProbe(element, names: names)
    firstFrames[name] = frame
    emitPoint("snapshot1_position_\(name)", frame.position)
    emitSize("snapshot1_size_\(name)", frame.size)
    emitBool("probe_position_\(name)_finished", true)
    emitBool("probe_size_\(name)_finished", true)
}

var activationReady = true
for (name, element) in [("grid", grid), ("image", image), ("label", label)] {
    let probe = activationProbe(element, names: firstNames[name], frame: firstFrames[name]?.frame)
    emitActivation(name, probe)
    emitBool("probe_activation_\(name)_finished", true)
    activationReady = activationReady && probe.ready
}
emitBool("activation_raw_rc_emitted", true)

let display1 = displayProbe()
emitRC("snapshot1_display_list_rc", Int(display1.rc.rawValue))
emitCount("snapshot1_active_display_count", display1.count)
emitBool("snapshot1_main_display_only", display1.mainOnly)
let cgMatches1 = cgWindowMatchCount(pid: pid, frame: firstFrames["window"]?.frame)
if let cgMatches1 = cgMatches1 { emitCount("snapshot1_cg_window_match_count", cgMatches1) }
else { emit("snapshot1_cg_window_match_count", "SKIPPED") }

func emitContainment(_ key: String, _ outer: CGRect?, _ inner: CGRect?) -> Bool? {
    let result: Bool? = outer.flatMap { outer in inner.map { contains(outer, $0) } }
    emitOptionalBool(key, result)
    return result
}

let windowFrame1 = firstFrames["window"]?.frame
let scrollFrame1 = firstFrames["scroll"]?.frame
let gridFrame1 = firstFrames["grid"]?.frame
let imageFrame1 = firstFrames["image"]?.frame
let labelFrame1 = firstFrames["label"]?.frame
let containments1: [Bool?] = [
    emitContainment("snapshot1_window_contains_scroll", windowFrame1, scrollFrame1),
    emitContainment("snapshot1_window_contains_grid", windowFrame1, gridFrame1),
    emitContainment("snapshot1_window_contains_image", windowFrame1, imageFrame1),
    emitContainment("snapshot1_window_contains_label", windowFrame1, labelFrame1),
    emitContainment("snapshot1_scroll_contains_grid", scrollFrame1, gridFrame1),
    emitContainment("snapshot1_grid_contains_image", gridFrame1, imageFrame1),
    emitContainment("snapshot1_grid_contains_label", gridFrame1, labelFrame1),
    emitContainment("snapshot1_display_contains_window", display1.bounds, windowFrame1),
    emitContainment("snapshot1_display_contains_scroll", display1.bounds, scrollFrame1),
    emitContainment("snapshot1_display_contains_grid", display1.bounds, gridFrame1),
    emitContainment("snapshot1_display_contains_image", display1.bounds, imageFrame1),
    emitContainment("snapshot1_display_contains_label", display1.bounds, labelFrame1)
]

Thread.sleep(forTimeInterval: 1.0)
let secondProcessGate = processGate(pid, expectedExecutable: expectedExecutable)
emit("snapshot2_process_gate", secondProcessGate ? "PASS" : "FAIL")
let secondSnapshot = Snapshot(root: AXUIElementCreateApplication(pid))
let topology2 = resolveTopology(secondSnapshot, pid: pid)
emitBool("snapshot2_topology_ready", topology2.topologyReady)

let secondGeometryNodes: [(String, AXUIElement?)] = [
    ("window", topology2.nodes?.window), ("scroll", topology2.nodes?.scroll),
    ("grid", topology2.nodes?.grid), ("image", topology2.nodes?.image),
    ("label", topology2.nodes?.label)
]
var secondFrames: [String: FrameProbe] = [:]
for (name, element) in secondGeometryNodes {
    let names = element.map(attributeNames)
    let frame = frameProbe(element, names: names)
    secondFrames[name] = frame
    emitPoint("snapshot2_position_\(name)", frame.position)
    emitSize("snapshot2_size_\(name)", frame.size)
    emitOptionalBool("position_\(name)_stable", stable(firstFrames[name]!.position, frame.position))
    emitOptionalBool("size_\(name)_stable", stable(firstFrames[name]!.size, frame.size))
}

let identityStable: Bool? = {
    guard let first = topology.nodes, let second = topology2.nodes else { return nil }
    return same(first.window, second.window) && same(first.scroll, second.scroll)
        && same(first.grid, second.grid) && same(first.image, second.image)
        && same(first.label, second.label)
}()
emitOptionalBool("snapshot_identity_stable", identityStable)

let display2 = displayProbe()
emitRC("snapshot2_display_list_rc", Int(display2.rc.rawValue))
emitCount("snapshot2_active_display_count", display2.count)
emitBool("snapshot2_main_display_only", display2.mainOnly)
let cgMatches2 = cgWindowMatchCount(pid: pid, frame: secondFrames["window"]?.frame)
if let cgMatches2 = cgMatches2 { emitCount("snapshot2_cg_window_match_count", cgMatches2) }
else { emit("snapshot2_cg_window_match_count", "SKIPPED") }

let windowFrame2 = secondFrames["window"]?.frame
let scrollFrame2 = secondFrames["scroll"]?.frame
let gridFrame2 = secondFrames["grid"]?.frame
let imageFrame2 = secondFrames["image"]?.frame
let labelFrame2 = secondFrames["label"]?.frame
let containments2: [Bool?] = [
    emitContainment("snapshot2_window_contains_scroll", windowFrame2, scrollFrame2),
    emitContainment("snapshot2_window_contains_grid", windowFrame2, gridFrame2),
    emitContainment("snapshot2_window_contains_image", windowFrame2, imageFrame2),
    emitContainment("snapshot2_window_contains_label", windowFrame2, labelFrame2),
    emitContainment("snapshot2_scroll_contains_grid", scrollFrame2, gridFrame2),
    emitContainment("snapshot2_grid_contains_image", gridFrame2, imageFrame2),
    emitContainment("snapshot2_grid_contains_label", gridFrame2, labelFrame2),
    emitContainment("snapshot2_display_contains_window", display2.bounds, windowFrame2),
    emitContainment("snapshot2_display_contains_scroll", display2.bounds, scrollFrame2),
    emitContainment("snapshot2_display_contains_grid", display2.bounds, gridFrame2),
    emitContainment("snapshot2_display_contains_image", display2.bounds, imageFrame2),
    emitContainment("snapshot2_display_contains_label", display2.bounds, labelFrame2)
]

let stableGeometry = geometryNodes.allSatisfy { entry in
    stable(firstFrames[entry.0]!.position, secondFrames[entry.0]!.position) == true
        && stable(firstFrames[entry.0]!.size, secondFrames[entry.0]!.size) == true
}
let allFramesReady1 = geometryNodes.allSatisfy { firstFrames[$0.0]?.ready == true }
let allFramesReady2 = geometryNodes.allSatisfy { secondFrames[$0.0]?.ready == true }
let containmentReady = containments1.allSatisfy { $0 == true } && containments2.allSatisfy { $0 == true }
let displayReady = display1.rc == .success && display1.count == 1 && display1.mainOnly
    && display2.rc == .success && display2.count == 1 && display2.mainOnly
let cgReady = cgMatches1 == 1 && cgMatches2 == 1
let capabilityReady = topology.topologyReady && gridCapability && imageCapability
    && labelCapability && relationReady
let geometryReady = topology.topologyReady && topology2.topologyReady && secondProcessGate
    && allFramesReady1 && allFramesReady2 && activationReady && containmentReady
    && displayReady && cgReady && stableGeometry && identityStable == true

emitBool("probe_display_finished", true)
emitBool("probe_containment_finished", true)
emitBool("probe_stability_finished", true)
emitCount("geometry_axvalue_decode_count", geometryAXValueDecodeCount)
emitBool("capability_ready", capabilityReady)
emitBool("geometry_ready", geometryReady)
emitBool("diagnostic_complete", true)
