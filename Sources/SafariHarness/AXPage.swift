import AppKit
import ApplicationServices
import Foundation
import SafariHarnessCore

enum PageError: Error, CustomStringConvertible {
    case webAreaNotFound(String)
    case elementNotFound(PageField)
    case focusFailed(PageField, String)
    case resetFailed(String)
    case selectionFailed(String)

    var description: String {
        switch self {
        case .webAreaNotFound(let path): return "Safari's accessibility tree has no web area for \(path) (is the harness tab frontmost, and is Accessibility granted?)"
        case .elementNotFound(let f): return "\(f.domID) was not found in the page's accessibility tree"
        case .focusFailed(let f, let why): return "could not focus \(f.domID): \(why)"
        case .resetFailed(let why): return "could not reset the page: \(why)"
        case .selectionFailed(let why): return "could not select text: \(why)"
        }
    }
}

/// The harness page as Safari exposes it through accessibility. Identity is `AXDOMIdentifier`
/// (falling back to the aria-label, which carries the same string); the web area's `AXURL` ties
/// every element back to the fixture file.
final class AXPage: PagePort {
    private let safariPID: pid_t
    private let fixturePath: String
    private let app: AXUIElement
    private let system = AXUIElementCreateSystemWide()
    private let js: JSBridge
    /// A live run may click as a last resort to focus a field; a dry run never posts events.
    private let allowMouse: Bool
    private var webAreaCache: (element: AXUIElement, path: String)?
    private var elementCache: [PageField: AXUIElement] = [:]

    static let maxNodes = 8000
    static let maxDepth = 40

    init(safariPID: pid_t, fixturePath: String, js: JSBridge, allowMouse: Bool) {
        self.safariPID = safariPID
        self.fixturePath = fixturePath
        self.js = js
        self.allowMouse = allowMouse
        app = AXUIElementCreateApplication(safariPID)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetMessagingTimeout(system, 0.5)
    }

    // MARK: Attribute helpers

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? { copy(element, attribute) as? String }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func children(_ parent: AXUIElement) -> [AXUIElement] {
        (copy(parent, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func domID(_ element: AXUIElement) -> String? {
        string(element, "AXDOMIdentifier").flatMap { $0.isEmpty ? nil : $0 }
            ?? string(element, kAXDescriptionAttribute).flatMap { $0.hasPrefix(HarnessConstants.domPrefix) ? $0 : nil }
    }

    private func resolvedPath(of url: URL) -> String { URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path }

    private func webAreaPath(_ element: AXUIElement) -> String? {
        guard string(element, kAXRoleAttribute) == "AXWebArea",
              let url = copy(element, "AXURL") as? URL else { return nil }
        return resolvedPath(of: url)
    }

    // MARK: Tree search

    /// Breadth-first, bounded, so a huge tab cannot hang the harness.
    private func search(from roots: [AXUIElement], where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = roots.map { ($0, 0) }
        var head = 0
        while head < queue.count, head < Self.maxNodes {
            let (node, depth) = queue[head]
            head += 1
            if match(node) { return node }
            if depth < Self.maxDepth { queue.append(contentsOf: children(node).map { ($0, depth + 1) }) }
        }
        return nil
    }

    func findWebArea() -> AXUIElement? {
        if let cache = webAreaCache, webAreaPath(cache.element) == fixturePath { return cache.element }
        webAreaCache = nil
        let windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let found = search(from: windows, where: { webAreaPath($0) == fixturePath }) else { return nil }
        webAreaCache = (found, fixturePath)
        return found
    }

    private func find(_ field: PageField, waiting seconds: Double = 0) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let cached = elementCache[field], domID(cached) == field.domID { return cached }
            elementCache[field] = nil
            if let area = findWebArea(), let found = search(from: [area], where: { domID($0) == field.domID }) {
                elementCache[field] = found
                return found
            }
            if seconds > 0 { Thread.sleep(forTimeInterval: 0.1) }
        } while Date() < deadline
        return nil
    }

    /// Polls until the harness page's web area is in Safari's tree.
    func waitForPage(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !SignalState.flag {
            if findWebArea() != nil, find(.plain) != nil { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // MARK: PagePort

    func focusSnapshot() throws -> FocusSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        var snapshot = FocusSnapshot(frontBundleID: front?.bundleIdentifier, frontPID: front?.processIdentifier)
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return snapshot }
        var pid: pid_t = 0
        if AXUIElementGetPid(focused, &pid) == .success { snapshot.focusedPID = pid }
        snapshot.focusedRole = string(focused, kAXRoleAttribute)
        snapshot.focusedDOMID = domID(focused)
        snapshot.webAreaPath = enclosingWebAreaPath(of: focused)
        return snapshot
    }

    private func enclosingWebAreaPath(of start: AXUIElement) -> String? {
        var node = start
        for _ in 0..<Self.maxDepth {
            if let cache = webAreaCache, CFEqual(cache.element, node) { return cache.path }
            if let path = webAreaPath(node) { return path }
            guard let parent = element(node, kAXParentAttribute) else { return nil }
            node = parent
        }
        return nil
    }

    func reset() throws {
        activateSafari()
        guard let button = find(.reset, waiting: 3) else { throw PageError.elementNotFound(.reset) }
        let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        if !pressed, !js.reset() { throw PageError.resetFailed("AXPress on dth-reset failed and JavaScript is not available") }
        elementCache.removeAll()
        Thread.sleep(forTimeInterval: 0.25)
        let plain = read(.plain)
        if let value = plain.jsValue ?? plain.axValue, !value.isEmpty {
            throw PageError.resetFailed("dth-plain still holds \(String(reflecting: value)) after the reset")
        }
    }

    func focus(_ field: PageField) throws {
        activateSafari()
        guard let target = find(field, waiting: 3) else { throw PageError.elementNotFound(field) }
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if waitForFocus(field, seconds: 1.0) { return }
        guard allowMouse else {
            throw PageError.focusFailed(field, "AX focus did not take (a live run would try a click)")
        }
        try click(field, element: target)
        guard waitForFocus(field, seconds: 1.0) else { throw PageError.focusFailed(field, "neither AX focus nor a click moved focus there") }
    }

    private func waitForFocus(_ field: PageField, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let snapshot = try? focusSnapshot(), snapshot.focusedDOMID == field.domID,
               snapshot.frontBundleID == HarnessConstants.safariBundleID { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// Last-resort focus. Checks the point resolves to this very control before clicking.
    private func click(_ field: PageField, element target: AXUIElement) throws {
        guard let positionValue = copy(target, kAXPositionAttribute), let sizeValue = copy(target, kAXSizeAttribute) else {
            throw PageError.focusFailed(field, "no frame to click")
        }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 4, size.height > 4 else {
            throw PageError.focusFailed(field, "unreadable frame")
        }
        let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit, domID(hit) == field.domID else {
            throw PageError.focusFailed(field, "the point (\(Int(point.x)), \(Int(point.y))) does not hit \(field.domID)")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func read(_ field: PageField) -> FieldReading {
        var reading = FieldReading(field: field)
        if let target = find(field, waiting: 0.4) {
            reading.axValue = string(target, kAXValueAttribute)
            reading.axRole = string(target, kAXRoleAttribute)
            if let rangeValue = copy(target, kAXSelectedTextRangeAttribute) {
                var range = CFRange()
                if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) { reading.caret = range.location }
            }
        } else {
            reading.note = "AX element not found (replaced by another control, or not rendered)"
        }
        if js.available, let values = js.values() { reading.jsValue = values[field.domID] }
        return reading
    }

    func selectAll(_ field: PageField) throws -> String? {
        guard let target = find(field, waiting: 2), let value = string(target, kAXValueAttribute) else {
            throw PageError.selectionFailed("\(field.domID) value is unreadable")
        }
        var range = CFRange(location: 0, length: (value as NSString).length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            throw PageError.selectionFailed("AX refused the selection range on \(field.domID)")
        }
        Thread.sleep(forTimeInterval: 0.15)
        return string(target, kAXSelectedTextAttribute)
    }

    func secureInputEnabled() -> Bool { SystemFacts.secureInputEnabled() }

    func drainPageLog() -> [String] { js.drain() }

    private func activateSafari() {
        guard let safari = NSRunningApplication(processIdentifier: safariPID) else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != safariPID {
            safari.activate()
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline, NSWorkspace.shared.frontmostApplication?.processIdentifier != safariPID {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
