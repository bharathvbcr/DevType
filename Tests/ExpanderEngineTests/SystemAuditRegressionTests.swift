import CryptoKit
import Darwin
import XCTest
@testable import ExpanderEngine

final class SystemAuditRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-system-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    private func secretStore(_ tier: SecretBackingStore) -> ConsolidatedSecretBackingStore {
        ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("secrets.enc"),
            tier: tier, diagnostics: SecretAccessDiagnostics()
        )
    }

    func testSecretQuarantineNeverDeletesAnEarlierRecoveryCopy() throws {
        let url = directory.appendingPathComponent("secrets.enc")
        let aside = url.appendingPathExtension("unreadable")
        let earlier = Data("earlier-recoverable-ciphertext".utf8)
        let newer = Data("newer-recoverable-ciphertext".utf8)
        try earlier.write(to: aside)
        try newer.write(to: url)
        let store = secretStore(InMemorySecretBackingStore())
        XCTAssertEqual(store.set("new-secret", account: UUID().uuidString), errSecSuccess)
        XCTAssertEqual(try Data(contentsOf: aside), earlier)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("unreadable") }
        XCTAssertTrue(try candidates.contains { try Data(contentsOf: $0) == newer })
    }

    func testUnreadableArchivePathRefusesReadWriteAndDelete() throws {
        let url = directory.appendingPathComponent("secrets.enc")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let tier = InMemorySecretBackingStore()
        let account = UUID().uuidString
        XCTAssertEqual(tier.set("retained", account: account), errSecSuccess)
        let store = secretStore(tier)
        XCTAssertNil(store.value(account: account))
        XCTAssertEqual(store.set("replacement", account: account), errSecIO)
        XCTAssertEqual(store.delete(account: account), errSecIO)
        XCTAssertEqual(tier.value(account: account), "retained")
    }

    func testArchiveReadFailureCannotBeMistakenForAnEmptyStore() throws {
        guard getuid() != 0 else { throw XCTSkip("Permission-denial fixture requires a non-root user") }
        let tier = InMemorySecretBackingStore()
        let store = secretStore(tier)
        let url = directory.appendingPathComponent("secrets.enc")
        let account = UUID().uuidString
        XCTAssertEqual(store.set("original", account: account), errSecSuccess)
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try Data(contentsOf: url), "Verify the I/O fault actually took effect")
        XCTAssertEqual(store.set("unrelated", account: UUID().uuidString), errSecIO)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(store.value(account: account), "original")
    }

    func testFailedStaleArchiveEvictionCannotReportASuccessfulSecretSave() throws {
        guard getuid() != 0 else { throw XCTSkip("Permission-denial fixture requires a non-root user") }
        let store = secretStore(InMemorySecretBackingStore())
        let account = UUID().uuidString
        XCTAssertEqual(store.set("old", account: account), errSecSuccess)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertEqual(store.set("new", account: account), errSecIO)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(store.set("retried", account: account), errSecSuccess)
        XCTAssertEqual(store.value(account: account), "retried")
    }

    func testDiagnosticSubprocessOutputIsBounded() throws {
        let result = try XCTUnwrap(BoundedProcess.run(
            executable: "/usr/bin/head", arguments: ["-c", "2097152", "/dev/zero"]
        ))
        XCTAssertLessThanOrEqual(result.output.utf8.count, 1_048_576)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.outputComplete)
        XCTAssertFalse(result.succeeded)
    }

    func testDiagnosticSubprocessRetainsOutputWhenADescendantHoldsItsPipe() throws {
        let result = try XCTUnwrap(BoundedProcess.run(
            executable: "/bin/sh", arguments: ["-c", "printf ready; sleep 3 &"], timeout: 0.5
        ))
        XCTAssertTrue(result.output.hasPrefix("ready"))
        XCTAssertFalse(result.outputComplete)
        XCTAssertFalse(result.succeeded)
    }

    func testSubprocessFailureAndInvalidUTF8CannotPassIdentityVerification() throws {
        for script in ["printf identity; exit 7", "printf '\\377'"] {
            let result = try XCTUnwrap(BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", script]))
            XCTAssertFalse(result.succeeded)
        }
        for timeout in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude, 0] {
            let result = try XCTUnwrap(BoundedProcess.run(
                executable: "/usr/bin/true", arguments: [], timeout: timeout
            ))
            XCTAssertTrue(result.succeeded)
        }
    }

    func testAtomicPublishFailurePreservesDestinationAndCleansStaging() throws {
        let url = directory.appendingPathComponent("record.json")
        let original = Data("prior".utf8)
        try FilePermissions.atomicWrite(original, to: url)
        XCTAssertThrowsError(try FilePermissions.atomicWrite(Data("next".utf8), to: url) {
            throw POSIXError(.EIO)
        })
        XCTAssertEqual(try Data(contentsOf: url), original)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries, ["record.json"])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnsafeArchiveTypesAreRefusedWithoutBlockingOrTouchingTargets() throws {
        let archive = directory.appendingPathComponent("secrets.enc")
        let target = directory.appendingPathComponent("outside")
        let bytes = Data("preserve-target".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: target)
        let store = secretStore(InMemorySecretBackingStore())
        XCTAssertEqual(store.set("secret", account: "account"), errSecIO)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: archive)
        XCTAssertEqual(mkfifo(archive.path, 0o600), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(store.set("secret", account: "account"), errSecIO)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testQuarantineCeilingPreservesEveryRecoveryCopy() throws {
        let archive = directory.appendingPathComponent("secrets.enc")
        let bytes = Data("unreadable".utf8)
        try bytes.write(to: archive)
        for index in 0..<ConsolidatedSecretBackingStore.maximumQuarantinedArchives {
            try bytes.write(to: archive.appendingPathExtension("unreadable.\(index)"))
        }
        let store = secretStore(InMemorySecretBackingStore())
        XCTAssertEqual(store.set("secret", account: "account"), errSecIO)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
    }

    func testVoiceWriterRefusesRecordsThatRecoveryCannotRead() throws {
        let store = VoiceSessionStore(baseDirectory: directory)
        let id = VoiceSessionID()
        let dir = store.sessionDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = RawTranscript(text: "recoverable", localeIdentifier: "en_US", providerID: "fixture", modelVersion: "1")
        try store.saveRawTranscript(original, for: id)
        let before = try Data(contentsOf: dir.appendingPathComponent("raw-transcript.json"))
        let oversized = RawTranscript(
            text: String(repeating: "x", count: VoiceRecoveryService.ScanLimits.standard.maximumRawTranscriptBytes),
            localeIdentifier: "en_US", providerID: "fixture", modelVersion: "1"
        )
        XCTAssertThrowsError(try store.saveRawTranscript(oversized, for: id))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("raw-transcript.json")), before)
    }

    func testConcurrentVoiceWritersNeverLoseTheDestination() throws {
        let sessionID = VoiceSessionID()
        let stores = (0..<8).map { _ in VoiceSessionStore(baseDirectory: directory) }
        let sessionDirectory = stores[0].sessionDirectory(for: sessionID)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let raw = RawTranscript(text: "stable", localeIdentifier: "en_US", providerID: "fixture", modelVersion: "1")
        try stores[0].saveRawTranscript(raw, for: sessionID)
        let failures = AuditFailures()
        DispatchQueue.concurrentPerform(iterations: stores.count) { worker in
            for _ in 0..<250 {
                do { try stores[worker].saveRawTranscript(raw, for: sessionID) }
                catch { failures.record("write failed") }
                do {
                    let data = try Data(contentsOf: sessionDirectory.appendingPathComponent("raw-transcript.json"))
                    _ = try JSONDecoder().decode(RawTranscript.self, from: data)
                } catch { failures.record("destination missing or corrupt") }
            }
        }
        XCTAssertEqual(failures.count, 0)
    }

    func testAITokenBudgetRejectsNegativeInputs() {
        XCTAssertThrowsError(try AITokenBudget.evaluate(
            inputTokens: -1, instructionTokens: 0, framingTokens: 0,
            contextSize: 4096, tokenBudgetMultiplier: 1
        ))
        XCTAssertThrowsError(try AITokenBudget.evaluate(
            inputTokens: 10, instructionTokens: 0, framingTokens: 0,
            contextSize: 4096, tokenBudgetMultiplier: -1
        ))
    }

    func testSingleFlightRejectsInvalidDeadlinesWithoutStartingWork() async throws {
        let latch = SingleFlightLatch()
        let calls = Sendable_Counter()
        for timeout in [Double.nan, .infinity, -.infinity, -1, 0] {
            let value: String? = try await latch.run(timeout: timeout) {
                calls.increment()
                return "unexpected"
            }
            XCTAssertNil(value)
        }
        XCTAssertEqual(calls.value, 0)
        let value: String? = try await latch.run(timeout: .greatestFiniteMagnitude) { "bounded" }
        XCTAssertEqual(value, "bounded")
    }

    func testSingleFlightCompletionAndCancellationRacesRemainReusable() async throws {
        let latch = SingleFlightLatch()
        for index in 0..<200 {
            let task = Task {
                try await latch.run(timeout: 0.002) {
                    if index.isMultiple(of: 2) { try await Task.sleep(nanoseconds: 5_000_000) }
                    return "answer"
                }
            }
            if index.isMultiple(of: 3) { task.cancel() }
            do {
                let result = try await task.value
                XCTAssertTrue(result == nil || result == "answer")
            } catch is CancellationError {
                // Cancellation is an expected terminal outcome, never an abandoned waiter.
            }
            let after: String? = try await latch.run(timeout: 1) { "reusable" }
            XCTAssertEqual(after, "reusable")
        }
    }

    func testAITokenBudgetRejectsNonFiniteAndOverflowingInputsWithoutTrapping() {
        for multiplier in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try AITokenBudget.evaluate(
                inputTokens: 10, instructionTokens: 0, framingTokens: 0,
                contextSize: 4096, tokenBudgetMultiplier: multiplier
            ))
        }
        XCTAssertThrowsError(try AITokenBudget.evaluate(
            inputTokens: .max, instructionTokens: .max, framingTokens: .max,
            contextSize: .max, tokenBudgetMultiplier: 1
        ))
    }
}

private final class AuditFailures {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(message)
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
