import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// The one place a test stands up the whole of `TextInjectionPipeline` against a world it owns.
///
/// Nothing here reaches the machine the tests run on. The pasteboard is a uniquely named private
/// board, every key the pipeline posts goes to a recorder (`HIDKeyPoster.CommandEventIO` is the
/// chokepoint for backspaces, arrows, unicode, trailing keys and ⌘V alike), and what the pipeline
/// asks the system — trust, Secure Input, the frontmost app, the focused element — is answered by
/// `Page`, a scripted accessibility tree. The recorder doubles as the host: a posted backspace
/// deletes in whichever element the page says is focused and a posted ⌘V inserts the private
/// board's text there, so a typed expansion really erases and really pastes against the page, and
/// a test says what went wrong by changing the page, not by stubbing the pipeline.
///
/// `log` is the ordered record of what happened — focus queries, backspaces, ⌘V, keeps — because
/// most of what the pipeline guarantees is an order (wait, then query, then erase, then paste).
final class InjectionHarness {

    // MARK: - The scripted world

    /// One page of elements: which is focused and what each reports.
    final class Page {
        var focused: AXUIElement?
        var values: [String: String] = [:]
        var selections: [String: NSRange] = [:]
        var frames: [String: CGRect] = [:]
        var roles: [String: String] = [:]
        var pids: [String: pid_t] = [:]
        var unreadable: Set<String> = []

        func key(_ element: AXUIElement) -> String { String(describing: element) }

        func value(of element: AXUIElement) -> String? { values[key(element)] }

        /// What a reader of `element` sees right now.
        func access() -> DeliveryVerifier.TextAccess {
            .init(
                focusedElement: { [unowned self] in self.focused },
                numberOfCharacters: { [unowned self] element in
                    self.values[self.key(element)].map { ($0 as NSString).length }
                },
                selectedRange: { [unowned self] element in self.selections[self.key(element)] },
                stringForRange: { [unowned self] element, range in
                    guard let value = self.values[self.key(element)] else { return nil }
                    let text = value as NSString
                    guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
                    return text.substring(with: range)
                },
                observation: { [unowned self] element in
                    let k = self.key(element)
                    if self.unreadable.contains(k) {
                        return .init(value: nil, selectedText: nil, selectedRange: nil, target: element)
                    }
                    let range = self.selections[k]
                    return .init(value: self.values[k], selectedText: nil,
                                 caretLocation: range?.location, selectedRange: range, target: element)
                },
                frame: { [unowned self] element in self.frames[self.key(element)] },
                role: { [unowned self] element in self.roles[self.key(element)] },
                pid: { [unowned self] element in self.pids[self.key(element)] }
            )
        }

        /// The erase guard's view of the same field.
        func eraseAccess() -> EraseExecutor.TextAccess {
            EraseExecutor.TextAccess(
                value: { [unowned self] element in
                    self.unreadable.contains(self.key(element)) ? nil : self.values[self.key(element)]
                },
                selectedRange: { [unowned self] element in
                    self.unreadable.contains(self.key(element)) ? nil : self.selections[self.key(element)]
                },
                stringForRange: { [unowned self] element, range in
                    guard let value = self.values[self.key(element)] else { return nil }
                    let text = value as NSString
                    guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
                    return text.substring(with: range)
                },
                role: { [unowned self] element in self.roles[self.key(element)] },
                acceptsTextMutation: { _ in true }
            )
        }

        /// Types `text` into `element` at its caret, replacing what is selected.
        func insert(_ text: String, into element: AXUIElement) {
            let k = key(element)
            guard let value = values[k] else { return }
            let range = selections[k] ?? NSRange(location: (value as NSString).length, length: 0)
            let updated = (value as NSString).replacingCharacters(in: range, with: text)
            values[k] = updated
            selections[k] = NSRange(location: range.location + (text as NSString).length, length: 0)
        }

        /// One backspace: the selection if there is one, otherwise the grapheme before the caret.
        func deleteBackward(in element: AXUIElement) {
            let k = key(element)
            guard let value = values[k] else { return }
            let text = value as NSString
            var range = selections[k] ?? NSRange(location: text.length, length: 0)
            if range.length == 0 {
                guard range.location > 0 else { return }
                let previous = text.rangeOfComposedCharacterSequence(at: range.location - 1)
                range = previous
            }
            values[k] = text.replacingCharacters(in: range, with: "")
            selections[k] = NSRange(location: range.location, length: 0)
        }
    }

    /// One thing that happened, in order.
    enum Event: Equatable {
        /// The pipeline asked AX which element is focused.
        case focusQuery
        /// A delete key went out; the host acted on it (or dropped it).
        case backspace
        /// The ⌘V chord's V went out; the host pasted (or did not).
        case paste(landed: Bool)
        /// The chord's closing Command-up.
        case chordDone
        /// A key other than backspace and ⌘V: its virtual key code.
        case key(Int)
        /// The refused-replacement keeper was asked to hold this text.
        case keep(String)
    }

    // MARK: - Fixed cast

    let field = AXUIElementCreateApplication(5101)
    let window = AXUIElementCreateApplication(5102)
    let replacementNode = AXUIElementCreateApplication(5103)
    let elsewhere = AXUIElementCreateApplication(5104)
    let frame = CGRect(x: 40, y: 80, width: 600, height: 300)
    static let hostPID: pid_t = 900
    static let hostBundleID = "dev.devtype.injection-harness"

    // MARK: - Machine state the test scripts

    let page = Page()
    /// What the pipeline's gates are told about this process and this session.
    var trusted = true
    var secureInput = false
    var canPostEvents = true
    var frontmostPID: pid_t? = InjectionHarness.hostPID
    var frontmostBundleID: String? = InjectionHarness.hostBundleID

    // MARK: - What the test observes

    private(set) var log: [Event] = []
    var backspaces: Int { log.filter { $0 == .backspace }.count }
    var chords: Int { log.filter { $0 == .chordDone }.count }
    var kept: [String] { log.compactMap { if case .keep(let text) = $0 { text } else { nil } } }
    var toasts: [Bool] = []
    var focusQueries: Int { log.filter { $0 == .focusQuery }.count }
    /// What the board held at the instant the result was kept — the instant a miss is called.
    var boardAtKeep: [String?] = []
    var keepAnswer = true

    // MARK: - Host behaviour the test scripts

    /// Backspaces the host ignores before it starts deleting (a mirror that lags the keys).
    var hostDropsBackspaces = 0
    /// Whether a posted ⌘V inserts the board's text where focus is.
    var hostPastes = true
    /// Runs on every backspace, with the number of backspaces so far, after the host acted.
    var onBackspace: (InjectionHarness, Int) -> Void = { _, _ in }
    /// Runs once the first ⌘V chord is out — where a test lets the paste land, or focus slip.
    var afterPaste: (InjectionHarness) -> Void = { _ in }
    /// Marks the broker's pre-⌘V target check as failing without the page moving.
    var brokerRefusesTarget = false
    /// Set by a test once the target moved; the pipeline's continue-check then fails too.
    var targetMovedAfterPaste = false
    /// What the focus query answers; `nil` answers the page's focused element.
    var focusAnswer: (Int) -> AXContextChecker.FocusQueryResult? = { _ in nil }

    // MARK: - The wired system

    let board = NSPasteboard.withUniqueName()
    let broker: PasteboardBroker
    let poster: HIDKeyPoster
    let eraser: EraseExecutor
    let verifier: DeliveryVerifier
    let pipeline: TextInjectionPipeline
    private let defaults: UserDefaults
    private let suite: String

    struct NoLayout: KeyboardLayoutProviding {
        func currentSourceID() -> String? { nil }
        func keyCode(for character: Character) -> CGKeyCode? { nil }
    }

    private final class Box { weak var harness: InjectionHarness? }

    /// - Parameters:
    ///   - selectionConfirmer: the replace confirmer; a test scripts it when the selection is the thing under test.
    init(
        selectionConfirmer: SelectionReplacementGuard.Confirmer = SelectionReplacementGuard.Confirmer(),
        trusted: Bool = true,
        secureInput: Bool = false
    ) throws {
        self.trusted = trusted
        self.secureInput = secureInput
        suite = "InjectionHarness.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let box = Box()

        for element in [field, replacementNode, elsewhere] {
            let k = page.key(element)
            page.roles[k] = "AXTextArea"
            page.pids[k] = Self.hostPID
            page.frames[k] = frame
        }
        page.roles[page.key(window)] = "AXWindow"
        page.pids[page.key(window)] = Self.hostPID
        page.focused = field

        verifier = DeliveryVerifier(access: page.access())

        let board = board
        poster = HIDKeyPoster(
            commandEventIO: .init(
                canPost: { box.harness?.canPostEvents ?? false },
                post: { event in box.harness?.host(event) },
                pause: {}
            ),
            layout: KeyboardLayoutState(provider: NoLayout())
        )
        var brokerEnvironment = PasteboardBroker.Environment()
        brokerEnvironment.pasteboard = { board }
        brokerEnvironment.canPostEvents = { box.harness?.canPostEvents ?? false }
        brokerEnvironment.secureInputActive = { box.harness?.secureInput ?? false }
        brokerEnvironment.frontmostPID = { box.harness?.frontmostPID }
        brokerEnvironment.targetCurrent = { target, _, checkElement in
            guard let harness = box.harness else { return false }
            if harness.brokerRefusesTarget || harness.targetMovedAfterPaste { return false }
            return target.mismatch(
                pid: harness.frontmostPID, element: harness.page.focused, range: target.range,
                checkRange: false, checkElement: checkElement
            ) == nil
        }
        broker = PasteboardBroker(
            hid: poster, verifier: verifier, timing: InjectTimingStore(), environment: brokerEnvironment
        )
        eraser = EraseExecutor(
            hid: poster, textAccess: page.eraseAccess(),
            settle: AXSettleRetry(isMainThread: { true }, sleep: { _ in }, scheduleOnMain: { _, work in work() })
        )

        var environment = TextInjectionPipeline.Environment()
        environment.isProcessTrusted = { box.harness?.trusted ?? false }
        environment.secureInputActive = { box.harness?.secureInput ?? false }
        environment.canPostEvents = { box.harness?.canPostEvents ?? false }
        environment.permissionSnapshot = {
            let harness = box.harness
            return PermissionSnapshot(
                canListenTap: true, canUseAX: harness?.trusted ?? false,
                canPostEvents: harness?.canPostEvents ?? false
            )
        }
        environment.frontmostApp = {
            .init(processIdentifier: box.harness?.frontmostPID, bundleIdentifier: box.harness?.frontmostBundleID)
        }
        environment.focusedElement = { box.harness?.page.focused }
        environment.focusedRole = { element in box.harness?.page.roles[box.harness?.page.key(element) ?? ""] }
        environment.imeMarkedText = { _ in false }
        environment.shellLikeContext = { _ in false }
        environment.expandGate = { canUseAX, _, focus in
            let allowed = canUseAX && box.harness?.trusted == true
            let reason = allowed ? "ok" : "AXIsProcessTrusted false — expand blocked (fail-closed)"
            let snapshot = DiagnosticReport.ExpandGateSnapshot(
                canUseAX: canUseAX, axTrusted: box.harness?.trusted ?? false,
                focusedAvailable: focus.element != nil, isSecureField: false, hasIMEMarkedText: false,
                shouldBlockExpand: !allowed, blockReason: reason,
                focusedRole: focus.element.flatMap { box.harness?.page.roles[box.harness?.page.key($0) ?? ""] }
            )
            return AXContextChecker.ExpandGateDecision(
                shouldBlock: !allowed, reason: reason, snapshot: snapshot, focus: focus
            )
        }

        var keeper: ((String) -> Bool)!
        var focusQuery: ((@escaping (AXContextChecker.FocusQueryResult) -> Void) -> Void)!
        pipeline = TextInjectionPipeline(
            defaults: defaults,
            selectionConfirmer: selectionConfirmer,
            keepRefusedReplacement: { keeper($0) },
            focusQuery: { completion in focusQuery(completion) },
            clipboard: broker,
            verifier: verifier,
            deliveryTrust: { _, _ in true },
            environment: environment,
            hid: poster,
            eraser: eraser
        )
        keeper = { [unowned self] text in
            self.boardAtKeep.append(self.board.string(forType: .string))
            self.log.append(.keep(text))
            return self.keepAnswer
        }
        focusQuery = { [unowned self] completion in
            self.log.append(.focusQuery)
            let index = self.focusQueries
            if let scripted = self.focusAnswer(index) {
                completion(scripted)
            } else if let element = self.page.focused {
                completion(.available(element))
            } else {
                completion(.missing)
            }
        }
        box.harness = self
        pipeline.onReplaceNotLanded = { [unowned self] copied in self.toasts.append(copied) }
    }

    deinit {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - The host

    /// Every CGEvent the pipeline posts lands here, and the host acts on it.
    private func host(_ event: CGEvent) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // A modifier key reports as a flags change, and the flags say which way it went.
        let down = code == kVK_Command ? event.flags.contains(.maskCommand) : event.type == .keyDown
        switch code {
        case kVK_Delete where down:
            let index = backspaces + 1
            log.append(.backspace)
            if index > hostDropsBackspaces, let focused = page.focused {
                page.deleteBackward(in: focused)
            }
            onBackspace(self, index)
        case kVK_ANSI_V where down && event.flags.contains(.maskCommand):
            var landed = false
            if hostPastes, let focused = page.focused, let text = board.string(forType: .string) {
                page.insert(text, into: focused)
                landed = true
            }
            log.append(.paste(landed: landed))
        case kVK_Command where !down:
            log.append(.chordDone)
            if chords == 1 { afterPaste(self) }
        case kVK_Delete, kVK_ANSI_V, kVK_Command:
            break
        default:
            if down { log.append(.key(code)) }
        }
    }

    // MARK: - Scripting helpers

    /// Seeds the field with `text`, caret at the end.
    func seed(_ text: String, caret: Int? = nil, selection: Int = 0) {
        let k = page.key(field)
        page.values[k] = text
        page.selections[k] = NSRange(location: caret ?? (text as NSString).length, length: selection)
        page.focused = field
    }

    func resetLog() { log.removeAll() }

    /// Publishes the user's own clipboard on the private board.
    func seedUserClipboard(_ text: String = "the user's own clipboard") {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: - Runs

    struct Run {
        var outcome: PermissionCoordinator.InjectOutcome?
        var text: String?
    }

    /// One typed expansion: the trigger is in the field, the tap swallowed nothing, and the
    /// pipeline is asked to erase it and paste `result`. The page is seeded as `lead + trigger`.
    @discardableResult
    func typeExpansion(
        in test: XCTestCase,
        trigger: String = "`slm",
        lead: String = "say: ",
        result: String = "Sincerely, Slim",
        operationStillOurs: @escaping () -> Bool = { true },
        timeout: TimeInterval = 10
    ) -> Run {
        seed(lead + trigger)
        var outcome: PermissionCoordinator.InjectOutcome?
        let done = test.expectation(description: "typed expansion finished")
        pipeline.inject(
            snippet: SnippetModel(title: "Slim", triggerKeyword: trigger, replacementText: result),
            triggerLength: (trigger as NSString).length,
            swallowed: .notSwallowed,
            erasePlan: ErasePlan(text: trigger),
            preResolvedText: result,
            shouldContinue: { [unowned self] in !self.targetMovedAfterPaste && operationStillOurs() },
            targetFocus: .resolved(field),
            completion: { outcome = $0; done.fulfill() }
        )
        test.wait(for: [done], timeout: timeout)
        return Run(outcome: outcome, text: page.value(of: field))
    }

    /// A whole replace through `inject`: the selection is confirmed on the live field first (by the
    /// harness's `selectionConfirmer`), then the result is pasted over it.
    @discardableResult
    func injectReplace(
        in test: XCTestCase, original: String, result: String, timeout: TimeInterval = 10
    ) -> PermissionCoordinator.InjectOutcome? {
        var outcome: PermissionCoordinator.InjectOutcome?
        let done = test.expectation(description: "inject completed")
        pipeline.inject(
            snippet: SnippetModel(title: "AI", triggerKeyword: "", replacementText: result),
            triggerLength: 0,
            swallowed: .notSwallowed,
            erasePlan: .empty,
            preResolvedText: result,
            secureClipboardPaste: true,
            targetFocus: .resolved(field),
            replacingSelection: SelectionReplacement(original: original)
        ) {
            outcome = $0
            done.fulfill()
        }
        test.wait(for: [done], timeout: timeout)
        return outcome
    }

    /// One replace through the secure-paste path: the selection is already confirmed, only the
    /// ⌘V and what is read back remain.
    @discardableResult
    func replaceSelection(
        in test: XCTestCase,
        result: String,
        replacesSelection: Bool = true,
        operationStillOurs: @escaping () -> Bool = { true },
        timeout: TimeInterval = 10
    ) -> PermissionCoordinator.InjectOutcome? {
        seedUserClipboard()
        var outcome: PermissionCoordinator.InjectOutcome?
        let done = test.expectation(description: "replace finished")
        pipeline.injectSecureClipboardPasteOnMain(
            snippet: SnippetModel(title: "AI", triggerKeyword: "", replacementText: result),
            clipboardOverride: nil,
            swallowed: .notSwallowed,
            preResolvedText: result,
            trailingKeys: [],
            snippetLookup: nil,
            focus: .resolved(field),
            replacesSelection: replacesSelection,
            shouldContinue: { [unowned self] in !self.targetMovedAfterPaste && operationStillOurs() },
            operationIsCurrent: operationStillOurs,
            completion: { outcome = $0; done.fulfill() }
        )
        test.wait(for: [done], timeout: timeout)
        return outcome
    }
}
