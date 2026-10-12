import Carbon
import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// Layout provider that records which thread each HIToolbox-shaped call arrived on. The live
/// provider traps off main on macOS 27; this one counts instead so a regression fails a test
/// rather than killing the runner.
private final class RecordingLayoutProvider: KeyboardLayoutProviding {
    struct Layout {
        var sourceID: String?
        var codes: [Character: CGKeyCode]
    }

    static let us = Layout(sourceID: "com.apple.keylayout.US",
                           codes: ["c": CGKeyCode(kVK_ANSI_C), "v": CGKeyCode(kVK_ANSI_V)])
    /// Dvorak puts "c" on the physical J key and "v" on the physical period key.
    static let dvorak = Layout(sourceID: "com.apple.keylayout.Dvorak",
                               codes: ["c": CGKeyCode(kVK_ANSI_J), "v": CGKeyCode(kVK_ANSI_Period)])
    static let korean = Layout(sourceID: "com.apple.inputmethod.Korean.2SetKorean",
                               codes: ["c": CGKeyCode(kVK_ANSI_C), "v": CGKeyCode(kVK_ANSI_V)])

    private let lock = NSLock()
    private var layout: Layout
    private var _calls = 0
    private var _offMainCalls = 0

    init(_ layout: Layout) { self.layout = layout }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var offMainCalls: Int { lock.lock(); defer { lock.unlock() }; return _offMainCalls }

    func set(_ layout: Layout) { lock.lock(); self.layout = layout; lock.unlock() }

    private func record() -> Layout {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        if !Thread.isMainThread { _offMainCalls += 1 }
        return layout
    }

    func currentSourceID() -> String? { record().sourceID }
    func keyCode(for character: Character) -> CGKeyCode? { record().codes[character] }
}

private final class PostedKeys {
    private let lock = NSLock()
    private var codes: [Int64] = []
    func append(_ event: CGEvent) {
        lock.lock(); codes.append(event.getIntegerValueField(.keyboardEventKeycode)); lock.unlock()
    }
    var all: [Int64] { lock.lock(); defer { lock.unlock() }; return codes }
    /// Chord events are Command down, letter down, letter up, Command up.
    var letters: [Int64] { all.enumerated().filter { $0.offset % 4 == 1 }.map(\.element) }
}

final class KeyboardLayoutStateTests: XCTestCase {
    private func poster(_ keys: PostedKeys, _ state: KeyboardLayoutState,
                        pause: @escaping () -> Void = {}) -> HIDKeyPoster {
        HIDKeyPoster(commandEventIO: .init(canPost: { true }, post: { keys.append($0) }, pause: pause),
                     layout: state)
    }

    /// Runs `body` on `SelectionReader.readQueue` and waits for it on the main run loop.
    private func onReadQueue(_ body: @escaping () -> Void) {
        let done = expectation(description: "read queue")
        SelectionReader.readQueue.async { body(); done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    // MARK: - The crash

    /// The 1.2.1 crash: the brokered copy ran on `readQueue` and resolved the layout via TIS there.
    func testCopyChordOnReadQueueNeverResolvesLayoutOffMain() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.dvorak)
        let state = KeyboardLayoutState(provider: provider)
        state.refresh()
        let keys = PostedKeys()
        let hid = poster(keys, state)
        var posted = false
        onReadQueue { posted = hid.postCmdCKeyEvents() }
        XCTAssertTrue(posted)
        XCTAssertEqual(provider.offMainCalls, 0, "TIS-backed layout calls must never run off main")
        XCTAssertEqual(keys.letters, [Int64(kVK_ANSI_J)], "The primed Dvorak layout still drives the chord")
    }

    func testChordBeforeFirstRefreshFallsBackToANSIWithoutTouchingTheProvider() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.dvorak)
        let state = KeyboardLayoutState(provider: provider)
        let keys = PostedKeys()
        let hid = poster(keys, state)
        onReadQueue { _ = hid.postCmdCKeyEvents() }
        XCTAssertEqual(keys.letters, [Int64(kVK_ANSI_C)])
        XCTAssertEqual(provider.offMainCalls, 0)
        // The unprimed read asked main to prime; it lands without anyone blocking.
        let primed = expectation(description: "primed on main")
        DispatchQueue.main.async { primed.fulfill() }
        wait(for: [primed], timeout: 5)
        XCTAssertEqual(state.snapshot().keyCodes["c"], CGKeyCode(kVK_ANSI_J))
        XCTAssertEqual(provider.offMainCalls, 0)
    }

    func testPasteChordOffMainUsesSnapshotToo() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.dvorak)
        let state = KeyboardLayoutState(provider: provider)
        state.refresh()
        let keys = PostedKeys()
        let hid = poster(keys, state)
        let done = expectation(description: "paste")
        DispatchQueue.global().async {
            hid.postCmdVKeyEventsAsync { _ in done.fulfill() }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(provider.offMainCalls, 0)
    }

    // MARK: - Layout changes

    func testLayoutChangeUpdatesChordKeyCodeAndHangulFlag() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.us)
        let state = KeyboardLayoutState(provider: provider)
        let hid = poster(PostedKeys(), state)
        state.refresh()
        XCTAssertEqual(hid.virtualKeyCode(for: "c"), CGKeyCode(kVK_ANSI_C))
        XCTAssertFalse(state.snapshot().isTwoSetKorean)

        provider.set(RecordingLayoutProvider.dvorak)
        state.refresh()
        XCTAssertEqual(hid.virtualKeyCode(for: "c"), CGKeyCode(kVK_ANSI_J))
        XCTAssertEqual(hid.virtualKeyCode(for: "v"), CGKeyCode(kVK_ANSI_Period))
        XCTAssertFalse(state.snapshot().isTwoSetKorean)

        provider.set(RecordingLayoutProvider.korean)
        state.refresh()
        XCTAssertTrue(state.snapshot().isTwoSetKorean, "2-Set Korean arms the physical-Hangul fallback")

        provider.set(RecordingLayoutProvider.us)
        state.refresh()
        XCTAssertFalse(state.snapshot().isTwoSetKorean)
    }

    func testListenersRunOnMainAfterEveryRefresh() {
        let state = KeyboardLayoutState(provider: RecordingLayoutProvider(RecordingLayoutProvider.us))
        var fired = 0
        let token = state.addChangeListener {
            XCTAssertTrue(Thread.isMainThread)
            fired += 1
        }
        state.refresh()
        state.refresh()
        XCTAssertEqual(fired, 2)
        state.removeChangeListener(token)
        state.refresh()
        XCTAssertEqual(fired, 2)
    }

    // MARK: - Notification delivery

    /// The live observer is registered with `queue: nil`: delivery is on the poster's thread.
    func testChangeNotificationFromBackgroundThreadRefreshesOnMain() {
        let center = NotificationCenter()
        let name = NSNotification.Name("test.KeyboardLayoutStateTests.changed")
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.us)
        let state = KeyboardLayoutState(provider: provider, center: center, changeName: name)
        state.refresh()

        let refreshed = expectation(description: "listener after refresh")
        var listenerOnMain = false
        state.addChangeListener {
            listenerOnMain = Thread.isMainThread
            refreshed.fulfill()
        }
        provider.set(RecordingLayoutProvider.dvorak)
        DispatchQueue.global().async { center.post(name: name, object: nil) }
        wait(for: [refreshed], timeout: 10)
        XCTAssertTrue(listenerOnMain)
        XCTAssertEqual(provider.offMainCalls, 0, "The observer must hop to main before it reads the layout")
        XCTAssertEqual(state.snapshot().keyCodes["c"], CGKeyCode(kVK_ANSI_J))
    }

    // MARK: - Adversarial

    func testEmptyLayoutDataYieldsEmptySnapshotAndANSIFallback() {
        let provider = RecordingLayoutProvider(.init(sourceID: nil, codes: [:]))
        let state = KeyboardLayoutState(provider: provider)
        state.refresh()
        XCTAssertEqual(state.snapshot(), KeyboardLayoutState.Snapshot())
        let keys = PostedKeys()
        onReadQueue { _ = self.poster(keys, state).postCmdCKeyEvents() }
        XCTAssertEqual(keys.letters, [Int64(kVK_ANSI_C)])
    }

    func testSourceWithoutLayoutDataStillReportsSourceID() {
        let state = KeyboardLayoutState(provider: RecordingLayoutProvider(
            .init(sourceID: RecordingLayoutProvider.korean.sourceID, codes: [:])))
        state.refresh()
        XCTAssertTrue(state.snapshot().isTwoSetKorean)
        XCTAssertNil(state.keyCode(for: "c"))
    }

    func testUnknownAndUnprimedCharactersResolveToNil() {
        let state = KeyboardLayoutState(provider: RecordingLayoutProvider(RecordingLayoutProvider.us))
        state.refresh()
        XCTAssertNil(state.keyCode(for: "🐢"))
        XCTAssertNil(state.keyCode(for: "z"), "Only the chord characters are primed")
    }

    func testLayoutSwitchMidReadKeepsTheChordConsistentAndNextReadSeesNewLayout() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.us)
        let state = KeyboardLayoutState(provider: provider)
        state.refresh()
        let keys = PostedKeys()
        let inPause = expectation(description: "chord paused")
        let release = DispatchSemaphore(value: 0)
        var paused = false   // `pause` runs twice per chord; only the first gap blocks
        let hid = poster(keys, state, pause: {
            guard !paused else { return }
            paused = true
            inPause.fulfill()
            release.wait()
        })
        let done = expectation(description: "chord done")
        SelectionReader.readQueue.async { _ = hid.postCmdCKeyEvents(); done.fulfill() }

        wait(for: [inPause], timeout: 10)
        provider.set(RecordingLayoutProvider.dvorak)
        state.refresh()                       // main switches layout while the read is mid-chord
        release.signal()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(keys.letters, [Int64(kVK_ANSI_C)], "The in-flight chord keeps the layout it started with")
        let second = PostedKeys()
        onReadQueue { _ = self.poster(second, state).postCmdCKeyEvents() }
        XCTAssertEqual(second.letters, [Int64(kVK_ANSI_J)])
        XCTAssertEqual(provider.offMainCalls, 0)
    }

    // MARK: - Stress

    /// 1,000 chords on `readQueue` while main refreshes the layout 1,000 times. Every chord must
    /// use a complete snapshot (never a torn or half-written one) and nothing touches the
    /// provider off main.
    func testThousandChordsOnReadQueueInterleavedWithMainRefreshes() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.us)
        let state = KeyboardLayoutState(provider: provider)
        state.refresh()
        let keys = PostedKeys()
        let hid = poster(keys, state)
        let done = expectation(description: "1000 chords")
        SelectionReader.readQueue.async {
            for _ in 0..<1000 { _ = hid.postCmdCKeyEvents() }
            done.fulfill()
        }
        for i in 0..<1000 {
            provider.set(i.isMultiple(of: 2) ? RecordingLayoutProvider.dvorak : RecordingLayoutProvider.us)
            state.refresh()
        }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(keys.letters.count, 1000)
        let valid: Set<Int64> = [Int64(kVK_ANSI_C), Int64(kVK_ANSI_J)]
        XCTAssertTrue(keys.letters.allSatisfy { valid.contains($0) })
        XCTAssertEqual(provider.offMainCalls, 0)
    }

    func testSnapshotReadsFromManyThreadsNeverTearWhileMainRefreshes() {
        let provider = RecordingLayoutProvider(RecordingLayoutProvider.us)
        let state = KeyboardLayoutState(provider: provider)
        state.refresh()
        let tornLock = NSLock()
        var torn = 0
        let done = expectation(description: "hammer")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                for _ in 0..<2000 {
                    let snap = state.snapshot()
                    let expectedC: CGKeyCode?
                    switch snap.sourceID {
                    case "com.apple.keylayout.US": expectedC = CGKeyCode(kVK_ANSI_C)
                    case "com.apple.keylayout.Dvorak": expectedC = CGKeyCode(kVK_ANSI_J)
                    default: expectedC = nil
                    }
                    if snap.keyCodes["c"] != expectedC {
                        tornLock.lock(); torn += 1; tornLock.unlock()
                    }
                }
            }
            done.fulfill()
        }
        for i in 0..<500 {
            provider.set(i.isMultiple(of: 2) ? RecordingLayoutProvider.dvorak : RecordingLayoutProvider.us)
            state.refresh()
        }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(torn, 0)
        XCTAssertEqual(provider.offMainCalls, 0)
    }
}
