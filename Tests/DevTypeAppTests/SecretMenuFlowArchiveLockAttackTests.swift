import Darwin
import XCTest
import ExpanderEngine
import SourceTreeTestSupport
@testable import DevTypeAppCore

/// Adversarial checks for the off-main archive lease. The only secret value asserted is "synthetic".
final class SecretMenuFlowArchiveLockAttackTests: XCTestCase {
    private let secretValue = "synthetic"

    private final class InlineAuthorizer: BiometricAuthenticating {
        func availability() -> BiometricGate.Availability { .passwordOnly }
        func evaluate(reason: String, completion: @escaping (BiometricGate.Outcome) -> Void) {
            XCTAssertTrue(Thread.isMainThread)
            completion(.authorized)
        }
        func invalidate() {}
    }

    private final class ManualUptime: @unchecked Sendable {
        private let lock = NSLock()
        private var now: TimeInterval
        private var reads = 0

        init(_ now: TimeInterval = 0) { self.now = now }

        func read() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return now
        }

        func jump(to value: TimeInterval) {
            lock.lock()
            now = value
            lock.unlock()
        }

        var sampleCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var ranBody = false
        private var granted = false

        func finish(granted: Bool, ranBody: Bool) {
            lock.lock()
            self.granted = granted
            self.ranBody = ranBody
            done = true
            lock.unlock()
        }

        func snapshot() -> (done: Bool, granted: Bool, ranBody: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (done, granted, ranBody)
        }
    }

    /// Counts reads of one account and how many threads are inside that read at once.
    private final class CountingTier: SecretBackingStore, @unchecked Sendable {
        let secretAccount: String
        private let state = NSLock()
        private var calls = 0
        private var depth: [ObjectIdentifier: Int] = [:]
        private var active = 0
        private(set) var maxActiveThreads = 0

        init(secretAccount: String) { self.secretAccount = secretAccount }

        func set(_ value: String, account: String) -> OSStatus { errSecIO }
        func contains(account: String) -> Bool { false }
        func delete(account: String) -> OSStatus { errSecItemNotFound }
        func accounts() -> Set<String> { [] }

        func value(account: String) -> String? {
            guard account == secretAccount else { return nil }
            let id = ObjectIdentifier(Thread.current)
            state.lock()
            calls += 1
            depth[id, default: 0] += 1
            if depth[id] == 1 {
                active += 1
                maxActiveThreads = max(maxActiveThreads, active)
            }
            state.unlock()
            Thread.sleep(forTimeInterval: 0.02)
            state.lock()
            depth[id, default: 1] -= 1
            if depth[id] == 0 {
                depth[id] = nil
                active -= 1
            }
            state.unlock()
            return "synthetic"
        }

        func callCount() -> Int {
            state.lock()
            defer { state.unlock() }
            return calls
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeBacking(
        directory: URL,
        tier: SecretBackingStore,
        diagnostics: SecretAccessDiagnostics = SecretAccessDiagnostics(),
        clock: (() -> TimeInterval)? = nil
    ) -> (ConsolidatedSecretBackingStore, URL) {
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let backing = ConsolidatedSecretBackingStore(
            fileURL: url,
            tier: tier,
            diagnostics: diagnostics,
            automaticConsolidationClock: clock ?? { ProcessInfo.processInfo.systemUptime }
        )
        return (backing, url)
    }

    private func library(_ secret: SecretModel) throws -> SnippetStore {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret])).write(to: file)
        return SnippetStore(fileURL: file)
    }

    private func archiveStore(
        _ secret: SecretModel,
        clock: (() -> TimeInterval)? = nil
    ) throws -> (SecretStore, ConsolidatedSecretBackingStore, URL) {
        let directory = try makeDirectory()
        let tier = InMemorySecretBackingStore()
        let (backing, url) = makeBacking(directory: directory, tier: tier, clock: clock)
        let store = SecretStore(backing: backing)
        XCTAssertNoThrow(try store.store(secretValue, for: secret.id).get())
        return (store, backing, url)
    }

    /// Holds the in-process archive lease until the returned semaphore is signalled.
    private func holdLease(_ backing: ConsolidatedSecretBackingStore) -> DispatchSemaphore? {
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(backing.performExclusiveTransaction {
                holding.signal()
                _ = release.wait(timeout: .now() + 3)
            })
        }
        guard holding.wait(timeout: .now() + 2) == .success else {
            XCTFail("holder did not acquire the archive lease")
            release.signal()
            return nil
        }
        return release
    }

    private func pumpUntil(_ predicate: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return predicate()
    }

    private func sourceText() throws -> String {
        return try SourceTree.text("Sources/ExpanderEngine/Models/SecretStore.swift")
    }

    /// Brace-matched function starting at `signaturePrefix`, including its signature.
    private func swiftFunction(in source: String, signaturePrefix: String) -> String? {
        guard let signature = source.range(of: signaturePrefix),
              let open = source[signature.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var cursor = open
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[signature.lowerBound...cursor]) }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func holdExternalFileLock(archiveURL: URL) throws -> Int32 {
        let fd = open(
            archiveURL.appendingPathExtension("lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return fd
    }

    func testWithArchiveLockAndPauseOffMainDoNotCallThreadSleep() throws {
        let source = try sourceText()
        guard let lockFunction = swiftFunction(in: source, signaturePrefix: "private func withArchiveLock"),
              let pause = swiftFunction(in: source, signaturePrefix: "private func pauseOffMain") else {
            return XCTFail("withArchiveLock or pauseOffMain is gone")
        }
        XCTAssertFalse(lockFunction.contains("Thread.sleep"), "withArchiveLock must not call Thread.sleep")
        XCTAssertFalse(pause.contains("Thread.sleep"), "pauseOffMain must not call Thread.sleep")
        XCTAssertTrue(
            pause.contains("precondition(!Thread.isMainThread)"),
            "pauseOffMain must refuse the main thread before it waits"
        )
    }

    func testContendedResolveLetsMainRunThenDeliversOnMain() throws {
        XCTAssertTrue(Thread.isMainThread)
        let secret = SecretModel(title: "Contended")
        let library = try library(secret)
        let (store, backing, _) = try archiveStore(secret)
        guard let release = holdLease(backing) else { return }
        defer { release.signal() }

        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        let started = Date()
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library,
            gate: BiometricGate(authenticator: InlineAuthorizer()), preferenceEnabled: true
        ) {
            XCTAssertTrue(Thread.isMainThread)
            result = $0
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertNil(result)
        let mainRan = expectation(description: "main ran while the holder still owned the lease")
        DispatchQueue.main.async { mainRan.fulfill() }
        wait(for: [mainRan], timeout: 1)
        XCTAssertNil(result, "the secret must not surface while the lease is still held")
        release.signal()
        XCTAssertTrue(pumpUntil({ result != nil }, timeout: 2))
        XCTAssertEqual(result, .success(secretValue))
        XCTAssertTrue(Thread.isMainThread)
    }

    func testUncontendedResolveCompletesInlineIncludingAuthorizedGate() throws {
        XCTAssertTrue(Thread.isMainThread)
        let secret = SecretModel(title: "Inline")
        let library = try library(secret)
        let (store, _, _) = try archiveStore(secret)

        var ungated: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library, preferenceEnabled: false
        ) { ungated = $0 }
        XCTAssertEqual(ungated, .success(secretValue), "an uncontended read must finish before resolve returns")

        var gated: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library,
            gate: BiometricGate(authenticator: InlineAuthorizer()), preferenceEnabled: true
        ) { gated = $0 }
        XCTAssertEqual(
            gated, .success(secretValue),
            "an inline .authorized gate must finish the uncontended read before resolve returns"
        )
    }

    func testContainsAnswersWhileArchiveLeaseIsHeld() throws {
        XCTAssertTrue(Thread.isMainThread)
        let directory = try makeDirectory()
        let tier = InMemorySecretBackingStore()
        let (backing, _) = makeBacking(directory: directory, tier: tier)
        let account = UUID().uuidString
        let absent = UUID().uuidString
        XCTAssertEqual(backing.set(secretValue, account: account), errSecSuccess)
        guard let release = holdLease(backing) else { return }
        defer { release.signal() }
        let started = Date()
        XCTAssertTrue(backing.contains(account: account))
        XCTAssertFalse(backing.contains(account: absent))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
    }

    func testInjectedClockJumpFailsOffMainWaiterWithoutRunningBody() throws {
        let directory = try makeDirectory()
        let clock = ManualUptime()
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let (backing, url) = makeBacking(
            directory: directory, tier: tier, diagnostics: diagnostics, clock: { clock.read() }
        )
        let fd = try holdExternalFileLock(archiveURL: url)
        defer { flock(fd, LOCK_UN); close(fd) }

        let outcome = Outcome()
        DispatchQueue.global().async {
            var ranBody = false
            let granted = backing.performExclusiveTransaction { ranBody = true }
            outcome.finish(granted: granted, ranBody: ranBody)
        }
        XCTAssertTrue(
            pumpUntil({ clock.sampleCount >= 1 }, timeout: 1),
            "off-main waiter never sampled the injected clock"
        )
        clock.jump(to: 10_000)
        let started = Date()
        let returned = pumpUntil({ outcome.snapshot().done }, timeout: 2)
        let shot = outcome.snapshot()
        XCTAssertTrue(returned, "clock jump past the captured deadline did not unblock the waiter")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(shot.granted)
        XCTAssertFalse(shot.ranBody, "the timed-out waiter ran the transaction body")
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock timed out — transaction refused"))
    }

    func testInjectedClockJumpFailsMenuResolveWithoutHanging() throws {
        XCTAssertTrue(Thread.isMainThread)
        let secret = SecretModel(title: "Expired")
        let library = try library(secret)
        let clock = ManualUptime()
        let directory = try makeDirectory()
        let tier = InMemorySecretBackingStore()
        let diagnostics = SecretAccessDiagnostics()
        XCTAssertEqual(tier.set(secretValue, account: secret.id.uuidString), errSecSuccess)
        let (backing, url) = makeBacking(
            directory: directory, tier: tier, diagnostics: diagnostics, clock: { clock.read() }
        )
        let store = SecretStore(backing: backing)
        let fd = try holdExternalFileLock(archiveURL: url)
        defer { flock(fd, LOCK_UN); close(fd) }

        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        let started = Date()
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library,
            gate: BiometricGate(authenticator: InlineAuthorizer()), preferenceEnabled: true
        ) { result = $0 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertNil(result, "a busy lock is not a completed failure yet")
        XCTAssertGreaterThanOrEqual(clock.sampleCount, 1, "the deadline was not captured up front")
        let mainRan = expectation(description: "main ran while the file lock was still held")
        DispatchQueue.main.async { mainRan.fulfill() }
        wait(for: [mainRan], timeout: 1)
        XCTAssertNil(result)
        clock.jump(to: 10_000)
        XCTAssertTrue(pumpUntil({ result != nil }, timeout: 2))
        XCTAssertEqual(result, .failure(.secretUnavailable))
        XCTAssertEqual(tier.accounts(), [secret.id.uuidString])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock timed out — transaction refused"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testFrozenClockOffMainWaiterDoesNotSpinPastTheBound() throws {
        let directory = try makeDirectory()
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let (backing, url) = makeBacking(
            directory: directory, tier: tier, diagnostics: diagnostics, clock: { 0 }
        )
        let fd = try holdExternalFileLock(archiveURL: url)
        defer { flock(fd, LOCK_UN); close(fd) }

        let outcome = Outcome()
        DispatchQueue.global().async {
            var ranBody = false
            let granted = backing.performExclusiveTransaction { ranBody = true }
            outcome.finish(granted: granted, ranBody: ranBody)
        }
        let started = Date()
        let returned = pumpUntil({ outcome.snapshot().done }, timeout: 2)
        let elapsed = Date().timeIntervalSince(started)
        let shot = outcome.snapshot()
        XCTAssertTrue(
            returned && elapsed < 2,
            "frozen-clock off-main waiter still inside withArchiveLock after \(elapsed)s (body ran: \(shot.ranBody)); clock closure stayed at 0 while the captured deadline stayed 5s ahead"
        )
        if returned {
            XCTAssertFalse(shot.ranBody, "frozen-clock waiter ran the body without exclusion giving way")
            XCTAssertFalse(shot.granted)
            XCTAssertTrue(tier.accounts().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        } else {
            // The assertion above already failed. Drop the flock so this waiter can leave
            // before teardown, without treating that late return as success.
            flock(fd, LOCK_UN)
            _ = pumpUntil({ outcome.snapshot().done }, timeout: 2)
        }
    }

    func testOverlappingDeliverSecretWaitsRunOnceEachAfterRelease() throws {
        XCTAssertTrue(Thread.isMainThread)
        let directory = try makeDirectory()
        let id = UUID()
        let tier = CountingTier(secretAccount: id.uuidString)
        let (backing, _) = makeBacking(directory: directory, tier: tier)
        let secrets = SecretStore(backing: backing)
        guard let release = holdLease(backing) else { return }
        defer { release.signal() }

        let first = expectation(description: "first main wait")
        let second = expectation(description: "second main wait")
        var values: [String?] = []
        let inlineFirst = secrets.deliverSecret(for: id) { value in
            XCTAssertTrue(Thread.isMainThread)
            values.append(value)
            first.fulfill()
        }
        let inlineSecond = secrets.deliverSecret(for: id) { value in
            XCTAssertTrue(Thread.isMainThread)
            values.append(value)
            second.fulfill()
        }
        XCTAssertFalse(inlineFirst)
        XCTAssertFalse(inlineSecond)
        let mainRan = expectation(description: "main kept running while the lease was held")
        DispatchQueue.main.async { mainRan.fulfill() }
        wait(for: [mainRan], timeout: 1)
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(tier.callCount(), 0, "a busy lease ran a read before the holder released")
        release.signal()
        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(values, [secretValue, secretValue])
        XCTAssertEqual(tier.callCount(), 2, "each wait must run the locked read once")
        XCTAssertEqual(tier.maxActiveThreads, 1, "overlapping waits ran the read without exclusion")
    }

    func testReentrantValueInsideArchiveTransactionDoesNotDeadlock() throws {
        XCTAssertTrue(Thread.isMainThread)
        let directory = try makeDirectory()
        let tier = InMemorySecretBackingStore()
        let (backing, _) = makeBacking(directory: directory, tier: tier)
        let account = UUID().uuidString
        XCTAssertEqual(backing.set(secretValue, account: account), errSecSuccess)

        let started = Date()
        var seenOnMain: String?
        let mainGranted = backing.performExclusiveTransaction {
            seenOnMain = backing.value(account: account)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(mainGranted)
        XCTAssertEqual(seenOnMain, secretValue)

        let outcome = Outcome()
        let box = LockedString()
        DispatchQueue.global().async {
            var ranBody = false
            let granted = backing.performExclusiveTransaction {
                ranBody = true
                box.set(backing.value(account: account))
            }
            outcome.finish(granted: granted, ranBody: ranBody)
        }
        let offMainStarted = Date()
        XCTAssertTrue(
            pumpUntil({ outcome.snapshot().done }, timeout: 2),
            "nested value(account:) on the waiter deadlocked"
        )
        XCTAssertLessThan(Date().timeIntervalSince(offMainStarted), 2)
        let shot = outcome.snapshot()
        XCTAssertTrue(shot.granted)
        XCTAssertTrue(shot.ranBody)
        XCTAssertEqual(box.get(), secretValue)
    }

    func testSymlinkLockFileRefusesWithoutRunningBody() throws {
        let directory = try makeDirectory()
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let (backing, url) = makeBacking(directory: directory, tier: tier, diagnostics: diagnostics)
        let target = directory.appendingPathComponent("regular.lock")
        FileManager.default.createFile(atPath: target.path, contents: Data([0]))
        try FileManager.default.createSymbolicLink(
            at: url.appendingPathExtension("lock"), withDestinationURL: target
        )
        var ranBody = false
        XCTAssertFalse(backing.performExclusiveTransaction { ranBody = true })
        XCTAssertFalse(ranBody)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(backing.set(secretValue, account: UUID().uuidString), errSecIO)
        XCTAssertTrue(diagnostics.trail().contains("archive lock file invalid — transaction refused"))
    }

    func testFifoLockFileRefusesWithoutRunningBody() throws {
        let directory = try makeDirectory()
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let (backing, url) = makeBacking(directory: directory, tier: tier, diagnostics: diagnostics)
        let lockPath = url.appendingPathExtension("lock").path
        XCTAssertEqual(mkfifo(lockPath, S_IRUSR | S_IWUSR), 0)
        let outcome = Outcome()
        DispatchQueue.global().async {
            var ranBody = false
            let granted = backing.performExclusiveTransaction { ranBody = true }
            outcome.finish(granted: granted, ranBody: ranBody)
        }
        let started = Date()
        XCTAssertTrue(
            pumpUntil({ outcome.snapshot().done }, timeout: 2),
            "non-regular lock open blocked the waiter"
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let shot = outcome.snapshot()
        XCTAssertFalse(shot.granted)
        XCTAssertFalse(shot.ranBody)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock file invalid — transaction refused"))
    }

    func testMainSetWhileLeaseHeldReturnsWithoutBlockingRunLoop() throws {
        XCTAssertTrue(Thread.isMainThread)
        let directory = try makeDirectory()
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let (backing, url) = makeBacking(directory: directory, tier: tier, diagnostics: diagnostics)
        let account = UUID().uuidString
        XCTAssertEqual(backing.set(secretValue, account: account), errSecSuccess)
        let before = try Data(contentsOf: url)
        guard let release = holdLease(backing) else { return }
        defer { release.signal() }

        let started = Date()
        let status = backing.set("mutated", account: account)
        let elapsed = Date().timeIntervalSince(started)
        let drained = expectation(description: "main run loop drained after the refused set")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertLessThan(elapsed, 0.25, "synchronous main set blocked for \(elapsed)s while the lease was held")
        XCTAssertEqual(status, errSecIO, "synchronous main set did not fail closed while the lease was held")
        XCTAssertEqual(try Data(contentsOf: url), before, "refused main set changed the archive")
        XCTAssertTrue(
            diagnostics.trail().contains("archive transaction busy — transaction refused"),
            "main refusal was not the busy fail-closed path; trail: \(diagnostics.trail())"
        )
        XCTAssertFalse(diagnostics.trail().contains("archive lock timed out — transaction refused"))
    }
}

/// One string published from a transaction body to the test thread.
private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
