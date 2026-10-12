import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// The thread contract of `SelectionReader.readQueue`: nothing it runs may call a main-only API.
///
/// macOS 27 traps (`dispatch_assert_queue`) on the first main-only HIToolbox call, and
/// `NSWorkspace` is not documented as thread safe. These tests drive the whole explicit-action
/// read — AX probes, the live re-checks, the brokered-copy tier — through `Platform` and the
/// checker's probe seam and record which thread each seam ran on. Pattern:
/// `KeyboardLayoutStateTests`.
final class SelectionReaderThreadingTests: XCTestCase {
    private static let sourcePID: pid_t = 4242

    private final class Recorder {
        private let lock = NSLock()
        private var mainOnlyOffMain: [String] = []
        private var axOnMain: [String] = []
        private var calls: [String] = []

        func mainOnly(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            calls.append(name)
            if !Thread.isMainThread { mainOnlyOffMain.append(name) }
        }

        /// IPC that must never run on main (it blocks for the target app's reply).
        func offMainOnly(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            calls.append(name)
            if Thread.isMainThread { axOnMain.append(name) }
        }

        func note(_ name: String) {
            lock.lock(); calls.append(name); lock.unlock()
        }

        var violationsOffMain: [String] { lock.lock(); defer { lock.unlock() }; return mainOnlyOffMain }
        var ipcOnMain: [String] { lock.lock(); defer { lock.unlock() }; return axOnMain }
        func count(_ name: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls.filter { $0 == name }.count
        }
    }

    private func platform(_ recorder: Recorder) -> SelectionReader.Platform {
        SelectionReader.Platform(
            frontmostApp: {
                recorder.mainOnly("frontmostApp")
                return .init(pid: Self.sourcePID, bundleID: "com.example.threading-test")
            },
            isAXTrusted: { _ in recorder.note("isAXTrusted"); return true },
            canPostEvents: { recorder.note("canPostEvents"); return true },
            isSecureInputActive: { recorder.note("isSecureInputActive"); return false },
            isProcessFrontmost: { pid in
                recorder.note("isProcessFrontmost")
                return pid == Self.sourcePID
            }
        )
    }

    private func checker(_ recorder: Recorder) -> AXContextChecker {
        AXContextChecker(
            settle: AXSettleRetry(
                delay: 0, isMainThread: { false }, sleep: { _ in }, scheduleOnMain: { _, work in work() }
            ),
            focusProbes: { _ in
                recorder.offMainOnly("focusProbes")
                return .init(candidates: [], summary: "systemWide:noValue appScoped:noValue chain:noValue")
            },
            manualAccessibilityWrite: { _ in
                recorder.offMainOnly("manualAccessibilityWrite")
                return .attributeUnsupported
            }
        )
    }

    private func read(_ recorder: Recorder, from queue: DispatchQueue? = nil) -> SelectionReader.Outcome? {
        let delivered = expectation(description: "read delivered")
        var outcome: SelectionReader.Outcome?
        var deliveredOnMain = false
        let monitor = SelectionMonitor(
            defaults: UserDefaults(suiteName: "SelectionReaderThreadingTests.\(UUID().uuidString)")!,
            environment: .fixed()
        )
        let start = {
            SelectionReader.readExplicitAIAction(
                checker: self.checker(recorder),
                muteStore: AppMuteStore(fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("threading-mute-\(UUID().uuidString).json")),
                monitor: monitor,
                now: Date(),
                diagnostics: nil,
                clipboardCapture: {
                    recorder.offMainOnly("clipboardCapture")
                    return .captured("selected by the copy tier")
                },
                platform: self.platform(recorder)
            ) {
                outcome = $0
                deliveredOnMain = Thread.isMainThread
                delivered.fulfill()
            }
        }
        if let queue { queue.async(execute: start) } else { start() }
        wait(for: [delivered], timeout: 30)
        XCTAssertTrue(deliveredOnMain, "The outcome is delivered on main")
        return outcome
    }

    private func assertCopyTierRan(_ outcome: SelectionReader.Outcome?, _ recorder: Recorder,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .selection(let result)? = outcome else {
            return XCTFail("The ladder never reached the ⌘C tier: \(String(describing: outcome))",
                           file: file, line: line)
        }
        XCTAssertEqual(result.text, "selected by the copy tier", file: file, line: line)
        XCTAssertEqual(recorder.count("clipboardCapture"), 1, file: file, line: line)
    }

    /// Every tier of the explicit read, from a main-thread gesture: the one main-only seam
    /// (`NSWorkspace`) runs once, on main, before dispatch; the AX IPC and the copy never touch main.
    func testExplicitReadTouchesMainOnlyAPIsOnlyOnMain() {
        let recorder = Recorder()
        let outcome = read(recorder)
        assertCopyTierRan(outcome, recorder)
        XCTAssertEqual(recorder.violationsOffMain, [], "A main-only API ran on readQueue")
        XCTAssertEqual(recorder.ipcOnMain, [], "AX / copy IPC ran on the main thread")
        XCTAssertEqual(recorder.count("frontmostApp"), 1, "Resolved once per read, before dispatch")
        XCTAssertGreaterThan(recorder.count("focusProbes"), 0, "The AX tier must have run")
        XCTAssertEqual(recorder.count("isProcessFrontmost"), 1, "The live pre-copy re-check")
    }

    /// A caller off main (a future caller, a Task) must not smuggle `NSWorkspace` onto its own
    /// thread, nor block waiting for main.
    func testExplicitReadFromABackgroundCallerStillResolvesFrontmostOnMain() {
        let recorder = Recorder()
        let outcome = read(recorder, from: DispatchQueue(label: "test.background-caller"))
        assertCopyTierRan(outcome, recorder)
        XCTAssertEqual(recorder.violationsOffMain, [], "A main-only API ran off main")
        XCTAssertEqual(recorder.count("frontmostApp"), 1)
    }

    /// The pre-copy pid gate must fail closed when the source app is no longer active.
    func testCopyTierIsRefusedWhenSourceAppIsNoLongerActive() {
        let recorder = Recorder()
        var plat = platform(recorder)
        plat.isProcessFrontmost = { _ in recorder.note("isProcessFrontmost"); return false }
        let delivered = expectation(description: "delivered")
        var outcome: SelectionReader.Outcome?
        SelectionReader.readExplicitAIAction(
            checker: checker(recorder),
            muteStore: AppMuteStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("threading-mute-\(UUID().uuidString).json")),
            monitor: SelectionMonitor(
                defaults: UserDefaults(suiteName: "SelectionReaderThreadingTests.\(UUID().uuidString)")!,
                environment: .fixed()
            ),
            now: Date(),
            diagnostics: nil,
            clipboardCapture: { recorder.note("clipboardCapture"); return .captured("must not run") },
            platform: plat
        ) { outcome = $0; delivered.fulfill() }
        wait(for: [delivered], timeout: 30)
        XCTAssertEqual(recorder.count("clipboardCapture"), 0)
        if case .selection? = outcome { XCTFail("Copied from an app that lost focus") }
    }
}
