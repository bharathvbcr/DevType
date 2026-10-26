import ApplicationServices
import CoreGraphics
import Foundation

/// The one owner of "is the control focused now the control we started in?".
///
/// WebKit replaces the focused `AXUIElement` under a typed expansion or a paste, so element
/// identity (`CFEqual`) cannot answer that question and every path that follows a replacement
/// needs another one. They used to answer it separately (a frame rule in the verifier, another in
/// the erase continuation, a role set in both). This type is the whole policy; the erase
/// continuation, the paste follower, the delivery verifier and the AI replace confirm all ask it.
///
/// Evidence, weakest to strongest:
/// * process, text-entry role and on-screen frame — what every host publishes;
/// * stable identity attributes (`Attributes`) — what some hosts publish. Present on both sides
///   and different means a different control, whatever the frame says: a single-page app can
///   re-render another control at the same frame. Present on both and equal corroborates.
///   Absent on either side says nothing, so a host that publishes none is judged exactly as it
///   was before these attributes were read.
///
/// Corroboration never widens acceptance: it is reported, it does not relax the frame rule.
public struct ControlIdentity: Equatable {
    public var pid: pid_t?
    public var role: String?
    public var frame: CGRect?
    public var attributes: Attributes

    public init(pid: pid_t? = nil, role: String? = nil, frame: CGRect? = nil, attributes: Attributes = .none) {
        self.pid = pid
        self.role = role
        self.frame = frame
        self.attributes = attributes
    }

    /// Stable identity attributes as a host publishes them. Every field is nil when the host does
    /// not answer, and an empty answer is the same as none: WebKit returns `""` for an element
    /// with no DOM id and `[]` for one with no classes, and two unrelated controls that both have
    /// none must not read as equal.
    public struct Attributes: Equatable {
        /// `AXDOMIdentifier` — the element's DOM `id` (WebKit, Chromium).
        public let domIdentifier: String?
        /// `AXIdentifier` — the host's own accessibility identifier.
        public let identifier: String?
        /// `AXPlaceholderValue`.
        public let placeholder: String?
        /// `AXDOMClassList` — the DOM class names, unordered.
        public let domClassList: Set<String>?
        /// Role of the parent element (`AXParent`). A parent's wrapper is regenerated along with
        /// the child's, so the parent is compared by role and frame, never by element identity.
        public let parentRole: String?
        public let parentFrame: CGRect?

        public static let none = Attributes()

        public init(
            domIdentifier: String? = nil, identifier: String? = nil, placeholder: String? = nil,
            domClassList: [String]? = nil, parentRole: String? = nil, parentFrame: CGRect? = nil
        ) {
            func present(_ text: String?) -> String? {
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }
            self.domIdentifier = present(domIdentifier)
            self.identifier = present(identifier)
            self.placeholder = present(placeholder)
            let classes = Set((domClassList ?? []).compactMap(present))
            self.domClassList = classes.isEmpty ? nil : classes
            self.parentRole = present(parentRole)
            self.parentFrame = ControlIdentity.usableFrame(parentFrame)
        }
    }

    public enum Mark: String, Equatable {
        case domIdentifier, identifier, placeholder, domClassList, parent
    }

    /// What `compare` concluded.
    public enum Verdict: Equatable {
        /// Same process, a text-entry role, the same frame, and nothing either side publishes
        /// disagrees — but no attribute was published by both, so the frame is all there is.
        case frameOnly
        /// As `.frameOnly`, and at least one identity attribute is present on both sides and equal.
        case corroborated
        /// An attribute present on both sides differs: a different control, even at the same frame.
        case contradicted(Mark)
        /// Process, role or frame does not hold, or one could not be read.
        case notSame

        public var isSameControl: Bool {
            switch self {
            case .frameOnly, .corroborated: return true
            case .contradicted, .notSame: return false
            }
        }
    }

    // MARK: - Roles

    /// Roles an element swap may land on, before the erase and after it. `AXSecureTextField` is a
    /// text-entry role and is deliberately absent: a secure field is not a retarget destination.
    /// Unstable roles (combo box, menu, list) are absent too — they already skip element identity
    /// after the erase, and a swap onto one is not a text field we may paste into.
    static let insertionRetargetRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
    ]

    static func roleAllowsInsertionRetarget(_ role: String?) -> Bool {
        guard let role else { return false }
        return insertionRetargetRoles.contains(role)
    }

    // MARK: - Frames

    /// Screen points of slack for "this is the same control". WebKit's replacement node lands
    /// on the same text field; a different control does not sit one point away.
    static let frameTolerance: CGFloat = 1

    /// Nil when `frame` is missing, non-finite, or has no positive area.
    static func usableFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame else { return nil }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else {
            return nil
        }
        return frame
    }

    static func framesMatch(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let left = usableFrame(lhs), let right = usableFrame(rhs) else { return false }
        let slack = frameTolerance
        return abs(left.origin.x - right.origin.x) <= slack
            && abs(left.origin.y - right.origin.y) <= slack
            && abs(left.size.width - right.size.width) <= slack
            && abs(left.size.height - right.size.height) <= slack
    }

    // MARK: - Verdicts

    /// The first attribute present on both sides that differs, or nil. Nil is not "same": it is
    /// "nothing published on both sides disagrees", which is all a caller that has its own frame or
    /// text evidence needs from the attributes. Fail-closed when it is non-nil.
    static func conflict(_ baseline: Attributes, _ live: Attributes) -> Mark? {
        if let left = baseline.domIdentifier, let right = live.domIdentifier, left != right {
            return .domIdentifier
        }
        if let left = baseline.identifier, let right = live.identifier, left != right {
            return .identifier
        }
        if let left = baseline.placeholder, let right = live.placeholder, left != right {
            return .placeholder
        }
        // A control's classes move with its state (focused, invalid, hovered), so one list
        // containing the other is the same control in another state. Two lists that each have
        // a class the other lacks name different controls.
        if let left = baseline.domClassList, let right = live.domClassList,
           !left.isSubset(of: right), !right.isSubset(of: left) {
            return .domClassList
        }
        if let left = baseline.parentRole, let right = live.parentRole, left != right {
            return .parent
        }
        if let left = baseline.parentFrame, let right = live.parentFrame, !framesMatch(left, right) {
            return .parent
        }
        return nil
    }

    /// Whether some identity attribute is present on both sides and equal.
    static func corroborates(_ baseline: Attributes, _ live: Attributes) -> Bool {
        func equal<Value: Equatable>(_ left: Value?, _ right: Value?) -> Bool {
            guard let left, let right else { return false }
            return left == right
        }
        return equal(baseline.domIdentifier, live.domIdentifier)
            || equal(baseline.identifier, live.identifier)
            || equal(baseline.placeholder, live.placeholder)
            || equal(baseline.domClassList, live.domClassList)
    }

    /// Whether `live` may stand in for `baseline` after a node swap. Every condition must hold:
    /// same owning process, a text-entry role (never a secure field, combo box or web area), the
    /// same on-screen frame, and no identity attribute that both sides publish disagreeing. A
    /// missing answer for process, role or frame fails closed — "could not tell" is not "same
    /// control".
    static func compare(baseline: ControlIdentity, live: ControlIdentity) -> Verdict {
        guard let baselinePID = baseline.pid, let livePID = live.pid, baselinePID == livePID else {
            return .notSame
        }
        guard roleAllowsInsertionRetarget(live.role) else { return .notSame }
        guard framesMatch(baseline.frame, live.frame) else { return .notSame }
        if let mark = conflict(baseline.attributes, live.attributes) { return .contradicted(mark) }
        return corroborates(baseline.attributes, live.attributes) ? .corroborated : .frameOnly
    }

    // MARK: - Reading

    /// The attribute names, as strings: `AXDOMIdentifier` and `AXDOMClassList` are WebKit's and
    /// are not in the public AX headers (`kAXIdentifierAttribute`, `kAXPlaceholderValueAttribute`
    /// and `kAXParentAttribute` are).
    static let domIdentifierAttribute = "AXDOMIdentifier"
    static let domClassListAttribute = "AXDOMClassList"

    /// Reads whatever `element` publishes. An attribute the host does not answer is nil, never an
    /// error: that is the "absent" case every comparison treats as no evidence. Costs at most one
    /// AX read per attribute, and the element's messaging timeout bounds each of them.
    static func readAttributes(of element: AXUIElement) -> Attributes {
        func copy(_ attribute: String, from source: AXUIElement) -> CFTypeRef? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(source, attribute as CFString, &ref) == .success else { return nil }
            return ref
        }
        var parentRole: String?
        var parentFrame: CGRect?
        if let parentRef = copy(kAXParentAttribute, from: element),
           CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
            let parent = unsafeBitCast(parentRef, to: AXUIElement.self)
            AXContextChecker.applyMessagingTimeout(to: parent)
            parentRole = AXContextChecker.shared.focusedElementRole(element: parent)
            parentFrame = AXContextChecker.elementFrame(parent)
        }
        return Attributes(
            domIdentifier: copy(domIdentifierAttribute, from: element) as? String,
            identifier: copy(kAXIdentifierAttribute, from: element) as? String,
            placeholder: copy(kAXPlaceholderValueAttribute, from: element) as? String,
            domClassList: copy(domClassListAttribute, from: element) as? [String],
            parentRole: parentRole,
            parentFrame: parentFrame
        )
    }
}
