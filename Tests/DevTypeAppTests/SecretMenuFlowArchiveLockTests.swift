import Darwin
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Touch ID's completion runs on the main thread. A contended archive lease must not sleep that
/// thread; an uncontended read must still finish before `resolve` returns.
final class SecretMenuFlowArchiveLockTests: XCTestCase {
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
        private var now: TimeInterval = 0
        func read() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return now
        }
        func jump(to value: TimeInterval) {
            lock.lock()
            now = value
            lock.unlock()
        }
    }

    private func library(_ secret: SecretModel) throws -> SnippetStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret])).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SnippetStore(fileURL: file)
    }

    private func archiveStore(
        _ secret: SecretModel,
        value: String,
        clock: (() -> TimeInterval)? = nil
    ) throws -> (SecretStore, ConsolidatedSecretBackingStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let tier = InMemorySecretBackingStore()
        let backing = ConsolidatedSecretBackingStore(
            fileURL: url,
            tier: tier,
            diagnostics: SecretAccessDiagnostics(),
            automaticConsolidationClock: clock ?? { ProcessInfo.processInfo.systemUptime }
        )
        let store = SecretStore(backing: backing)
        XCTAssertNoThrow(try store.store(value, for: secret.id).get())
        return (store, backing, url)
    }

    func testUncontendedResolveCompletesBeforeReturning() throws {
        XCTAssertTrue(Thread.isMainThread)
        let secret = SecretModel(title: "Inline")
        let library = try library(secret)
        let (store, _, _) = try archiveStore(secret, value: "synthetic")
        var ungated: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(secret.snippetAdapter, secretStore: store, libraryStore: library,
                               preferenceEnabled: false) { ungated = $0 }
        XCTAssertEqual(ungated, .success("synthetic"), "an uncontended read must not hop")

        var gated: Result<String, SecretMenuFlow.ResolveFailure>?
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library,
            gate: BiometricGate(authenticator: InlineAuthorizer()), preferenceEnabled: true
        ) { gated = $0 }
        XCTAssertEqual(gated, .success("synthetic"), "Touch ID's inline success must not hop when the lease is free")
    }

    func testAuthorizedResolveWaitsOffMainWhileTheArchiveLeaseIsHeld() throws {
        try assertContendedResolveCompletesAfterRelease(preferenceEnabled: true)
    }

    func testUngatedResolveWaitsOffMainWhileTheArchiveLeaseIsHeld() throws {
        try assertContendedResolveCompletesAfterRelease(preferenceEnabled: false)
    }

    func testHeldLeasePastTheInjectedDeadlineFailsWithoutBlockingMainOrReading() throws {
        XCTAssertTrue(Thread.isMainThread)
        let secret = SecretModel(title: "Expired")
        let library = try library(secret)
        let clock = ManualUptime()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ConsolidatedSecretBackingStore.archiveFileName)
        let tier = InMemorySecretBackingStore()
        XCTAssertEqual(tier.set("synthetic", account: secret.id.uuidString), errSecSuccess)
        let backing = ConsolidatedSecretBackingStore(
            fileURL: url, tier: tier, diagnostics: SecretAccessDiagnostics(),
            automaticConsolidationClock: { clock.read() }
        )
        let store = SecretStore(backing: backing)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        let started = Date()
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library,
            gate: BiometricGate(authenticator: InlineAuthorizer()), preferenceEnabled: true
        ) { result = $0 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertNil(result, "a busy lock is not secretUnavailable yet")
        let mainRan = expectation(description: "main ran while the file lock was still held")
        DispatchQueue.main.async { mainRan.fulfill() }
        wait(for: [mainRan], timeout: 1)
        XCTAssertNil(result)
        clock.jump(to: 30)
        let deadline = Date().addingTimeInterval(2)
        while result == nil && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard case .failure = result else {
            return XCTFail("expected a failure after the deadline, got \(String(describing: result))")
        }
        XCTAssertEqual(tier.accounts(), [secret.id.uuidString], "the refused read must not touch the value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func assertContendedResolveCompletesAfterRelease(preferenceEnabled: Bool) throws {
        XCTAssertTrue(Thread.isMainThread)
        let secret = SecretModel(title: "Contended")
        let library = try library(secret)
        let (store, backing, _) = try archiveStore(secret, value: "synthetic")
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(backing.performExclusiveTransaction {
                holding.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            })
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 2), .success)
        var result: Result<String, SecretMenuFlow.ResolveFailure>?
        let gate = BiometricGate(authenticator: InlineAuthorizer())
        let started = Date()
        SecretMenuFlow.resolve(
            secret.snippetAdapter, secretStore: store, libraryStore: library,
            gate: gate, preferenceEnabled: preferenceEnabled
        ) { result = $0 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertNil(result)
        let mainRan = expectation(description: "main ran while the holder still owned the lease")
        DispatchQueue.main.async { mainRan.fulfill() }
        wait(for: [mainRan], timeout: 1)
        XCTAssertNil(result, "the copy must not surface secretUnavailable while the lease is busy")
        release.signal()
        let deadline = Date().addingTimeInterval(2)
        while result == nil && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(result, .success("synthetic"))
        XCTAssertTrue(Thread.isMainThread)
    }
}
