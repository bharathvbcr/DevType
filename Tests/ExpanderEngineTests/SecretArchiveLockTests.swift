import Darwin
import XCTest
@testable import ExpanderEngine

// §-audit hardening for `ConsolidatedSecretBackingStore.withArchiveLock`.
//
// An unavailable lock must be diagnosed AND refuse the transaction. The earlier
// fail-open expectation preserved single-instance availability by allowing the
// very cross-writer data loss that the archive lock is meant to prevent.

final class SecretArchiveLockTests: XCTestCase {

    func testCleanupRechecksLivenessAfterWaitingForAnotherArchiveTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.enc")
        let tier = InMemorySecretBackingStore()
        let writer = ConsolidatedSecretBackingStore(fileURL: url, tier: tier)
        let cleaner = SecretStore(backing: ConsolidatedSecretBackingStore(fileURL: url, tier: tier))
        let id = UUID()
        XCTAssertEqual(writer.set("synthetic", account: id.uuidString), errSecSuccess)
        let queried = DispatchSemaphore(value: 0)
        let finished = expectation(description: "cleanup reconsidered the candidate")
        let stateLock = NSLock()
        var live = false
        var queries = 0
        XCTAssertTrue(writer.performExclusiveTransaction {
            DispatchQueue.global().async {
                let result = cleaner.purgeOrphans(keepingLatest: {
                    stateLock.lock()
                    let keep = live
                    queries += 1
                    stateLock.unlock()
                    queried.signal()
                    return keep ? [id] : []
                })
                XCTAssertEqual(result.attempted, 0)
                XCTAssertEqual(result.removed, 0)
                finished.fulfill()
            }
            XCTAssertEqual(queried.wait(timeout: .now() + 3), .success)
            stateLock.lock()
            live = true
            stateLock.unlock()
        })
        wait(for: [finished], timeout: 8)
        stateLock.lock()
        let totalQueries = queries
        stateLock.unlock()
        XCTAssertGreaterThanOrEqual(totalQueries, 2)
        XCTAssertEqual(writer.value(account: id.uuidString), "synthetic")
    }

    func testUnavailableLockNeverChangesArchiveOrMasterKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        let sealed = UUID().uuidString
        let resident = UUID().uuidString
        XCTAssertEqual(store.set("sealed", account: sealed), errSecSuccess)
        XCTAssertEqual(tier.set("resident", account: resident), errSecSuccess)
        let bytes = try Data(contentsOf: url)
        let key = tier.value(account: ConsolidatedSecretBackingStore.masterKeyAccount)
        let lockURL = url.appendingPathExtension("lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        XCTAssertEqual(store.set("replacement", account: sealed), errSecIO)
        XCTAssertEqual(store.delete(account: sealed), errSecIO)
        XCTAssertNil(store.value(account: resident), "A read must not migrate without exclusion")
        XCTAssertEqual(store.consolidateIntoFile(), .init(moved: 0, remaining: 1, failed: 0))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(tier.value(account: ConsolidatedSecretBackingStore.masterKeyAccount), key)
        XCTAssertEqual(tier.value(account: resident), "resident")

        try FileManager.default.removeItem(at: lockURL)
        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        XCTAssertEqual(reopened.value(account: sealed), "sealed")
        XCTAssertEqual(reopened.value(account: resident), "resident")
    }

    func testLockOpenFailureIsRecordedAndStoreRecoversAfterRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        // A directory at the lock path makes open(O_CREAT | O_RDWR) fail with EISDIR,
        // deterministically and without touching real file permissions.
        try FileManager.default.createDirectory(
            at: archiveURL.appendingPathExtension("lock"),
            withIntermediateDirectories: false
        )

        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(
            fileURL: archiveURL, tier: tier, diagnostics: diagnostics
        )

        XCTAssertEqual(store.set("lockless-value", account: "acct-a"), errSecIO)
        XCTAssertNil(store.value(account: "acct-a"))
        XCTAssertFalse(store.contains(account: "acct-a"))
        XCTAssertEqual(store.delete(account: "acct-a"), errSecIO)
        XCTAssertTrue(tier.accounts().isEmpty, "Refusal must not create a master key or tier value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        let trail = diagnostics.trail()
        XCTAssertTrue(
            trail.contains("archive lock unavailable"),
            "an unavailable archive lock must be visible in the diagnostics trail; got \(trail)"
        )
        XCTAssertTrue(trail.contains { $0.contains("transaction refused") })

        try FileManager.default.removeItem(at: archiveURL.appendingPathExtension("lock"))
        XCTAssertEqual(store.set("lockless-value", account: "acct-a"), errSecSuccess)
        XCTAssertEqual(store.value(account: "acct-a"), "lockless-value")
        XCTAssertTrue(store.contains(account: "acct-a"))
        XCTAssertEqual(store.delete(account: "acct-a"), errSecSuccess)
    }

    func testNonregularLockPathRefusesWritesEvenWhenOpenSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        // A device opens successfully (and macOS can even accept flock on it), but it is
        // not a regular archive lock file. No bytes are written to the device.
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathExtension("lock").path,
                                                 withDestinationPath: "/dev/null")
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: diagnostics)
        XCTAssertEqual(store.set("refused", account: UUID().uuidString), errSecIO)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock file invalid — transaction refused"))
    }

    func testHeldArchiveLockTimesOutWithoutMutationAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        // Each read moves the injected uptime past the five-second lease, so the refusal does
        // not sleep for five real seconds. The waiter is off main: the main thread must not block.
        let clock = AdvancingUptime()
        let store = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: diagnostics,
            automaticConsolidationClock: { clock.read() }
        )
        let account = UUID().uuidString
        let refused = expectation(description: "off-main set hit the injected deadline")
        var status = errSecSuccess
        DispatchQueue.global().async {
            status = store.set("retryable", account: account)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 2)
        XCTAssertEqual(status, errSecIO)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive lock timed out — transaction refused"))

        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(store.set("retryable", account: account), errSecSuccess)
        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics())
        XCTAssertEqual(reopened.value(account: account), "retryable")
    }
    /// In-process contenders queue for the archive transaction instead of polling for a free
    /// instant. With polling, a waiter only ever saw the lock free if its 10 ms sample happened to
    /// land in the microsecond gap between two busy holders, so under load it starved to the
    /// five-second refusal while the lock was granted to everyone else.
    func testAWaiterIsNotStarvedBehindBackToBackTransactions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("synthetic.enc"),
            tier: InMemorySecretBackingStore(), diagnostics: SecretAccessDiagnostics()
        )
        let stop = NSLock()
        var stopped = false
        let holders = DispatchGroup()
        for _ in 0..<4 {
            holders.enter()
            DispatchQueue.global().async {
                while true {
                    stop.lock(); let done = stopped; stop.unlock()
                    if done { break }
                    _ = store.performExclusiveTransaction { Thread.sleep(forTimeInterval: 0.001) }
                }
                holders.leave()
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        let finished = expectation(description: "off-main waiter acquired the lease")
        var granted = false
        var waited: TimeInterval = 0
        DispatchQueue.global().async {
            let started = ProcessInfo.processInfo.systemUptime
            granted = store.performExclusiveTransaction {}
            waited = ProcessInfo.processInfo.systemUptime - started
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        stop.lock(); stopped = true; stop.unlock()
        holders.wait()

        XCTAssertTrue(granted, "a waiter behind busy holders was refused after \(waited)s")
        XCTAssertLessThan(waited, 1.0, "the waiter starved for \(waited)s behind back-to-back holders")
    }

    /// Background waiters used to hop with `async` inside `withoutActuallyEscaping`.
    /// The queue block was still alive when that scope returned, so a burst of
    /// off-main transactions trapped the process.
    func testConcurrentOffMainArchiveTransactionsDoNotTrap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("synthetic.enc"),
            tier: InMemorySecretBackingStore(), diagnostics: SecretAccessDiagnostics()
        )
        let group = DispatchGroup()
        let failures = NSLock()
        var refused = 0
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<40 {
                    if !store.performExclusiveTransaction({}) {
                        failures.lock()
                        refused += 1
                        failures.unlock()
                    }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(refused, 0, "an off-main transaction was refused while the lease was free")
    }

    func testWithArchiveLockDoesNotSleepAndMainRefusesAHeldFileLock() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExpanderEngine/Models/SecretStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let start = source.range(of: "private func withArchiveLock") else {
            return XCTFail("withArchiveLock is gone")
        }
        let tail = source[start.lowerBound...]
        guard let end = tail.range(of: "public func performExclusiveTransaction") else {
            return XCTFail("withArchiveLock no longer sits above performExclusiveTransaction")
        }
        let body = String(tail[..<end.lowerBound])
        XCTAssertFalse(body.contains("Thread.sleep"), "the archive lease must not sleep its caller")
        XCTAssertTrue(
            source.contains("precondition(!Thread.isMainThread)"),
            "a nanosleep on this path has to be refused on the main thread"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeArchiveLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let diagnostics = SecretAccessDiagnostics()
        let tier = InMemorySecretBackingStore()
        // Frozen uptime: a waiter that ignored "do not block main" would spin until the suite died.
        let store = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: diagnostics,
            automaticConsolidationClock: { 0 }
        )
        let started = Date()
        XCTAssertEqual(store.set("refused", account: UUID().uuidString), errSecIO)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertTrue(tier.accounts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(diagnostics.trail().contains("archive transaction busy — transaction refused"))
        XCTAssertFalse(diagnostics.trail().contains("archive lock timed out — transaction refused"))
    }

    func testContainsDoesNotTakeTheArchiveLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.enc")
        let tier = InMemorySecretBackingStore()
        let store = ConsolidatedSecretBackingStore(fileURL: url, tier: tier)
        let account = UUID().uuidString
        XCTAssertEqual(store.set("synthetic", account: account), errSecSuccess)
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(store.performExclusiveTransaction {
                holding.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            })
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 2), .success)
        let started = Date()
        XCTAssertTrue(store.contains(account: account))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25,
                          "contains must answer while another thread holds the archive lease")
        release.signal()
    }

    func testOverlappingMainWaitsDoNotRunTheBodyWithoutExclusion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = OverlapTier()
        let backing = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("synthetic.enc"), tier: tier
        )
        let secrets = SecretStore(backing: backing)
        let id = UUID()
        XCTAssertEqual(tier.set("synthetic", account: id.uuidString), errSecSuccess)
        tier.resetOverlap()
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(backing.performExclusiveTransaction {
                holding.signal()
                _ = release.wait(timeout: .now() + 3)
            })
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 2), .success)
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
        let pumped = expectation(description: "main kept running while the lease was held")
        DispatchQueue.main.async { pumped.fulfill() }
        wait(for: [pumped], timeout: 1)
        XCTAssertTrue(values.isEmpty, "a busy lock must not complete before the holder releases")
        release.signal()
        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(values, ["synthetic", "synthetic"])
        XCTAssertEqual(tier.maxActiveThreads, 1, "overlapping waits ran the read without exclusion")
    }
}

/// Uptime that jumps by more than the archive lease on every sample after the first.
private final class AdvancingUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 6
        return current
    }
}

/// Counts threads inside `value` so two archive reads cannot hide an overlap.
private final class OverlapTier: SecretBackingStore {
    private let inner = InMemorySecretBackingStore()
    private let state = NSLock()
    private var depth: [ObjectIdentifier: Int] = [:]
    private var active = 0
    private(set) var maxActiveThreads = 0

    func resetOverlap() {
        state.lock()
        depth.removeAll()
        active = 0
        maxActiveThreads = 0
        state.unlock()
    }

    func performExclusiveTransaction(_ body: () -> Void) -> Bool { false }

    func set(_ value: String, account: String) -> OSStatus { inner.set(value, account: account) }

    func value(account: String) -> String? {
        let id = ObjectIdentifier(Thread.current)
        state.lock()
        depth[id, default: 0] += 1
        if depth[id] == 1 {
            active += 1
            maxActiveThreads = max(maxActiveThreads, active)
        }
        state.unlock()
        defer {
            state.lock()
            depth[id, default: 1] -= 1
            if depth[id] == 0 {
                depth[id] = nil
                active -= 1
            }
            state.unlock()
        }
        Thread.sleep(forTimeInterval: 0.02)
        return inner.value(account: account)
    }

    func contains(account: String) -> Bool { inner.contains(account: account) }
    func delete(account: String) -> OSStatus { inner.delete(account: account) }
    func accounts() -> Set<String> { inner.accounts() }
}
