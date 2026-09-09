import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class DiagnosticHardeningTests: XCTestCase {
    func testUnverifiedPostsDoNotCountAsVerifiedSuccess() throws {
        let log = InjectTelemetryLog()
        log.record(outcome: .postedUnverified, bundleID: "com.example.editor")
        log.record(outcome: .degradedAXOnly, bundleID: "com.example.editor")
        let stats = try XCTUnwrap(log.statsByBundle()["com.example.editor"])
        XCTAssertEqual(stats.successRatio, 0)
        let report = log.summaryLines().joined(separator: "\n")
        XCTAssertTrue(report.contains("0% verified"), report)
        XCTAssertFalse(report.contains("100% delivered"), report)
    }

    func testVerifiedPercentageUsesEveryAttemptAsItsDenominator() throws {
        let log = InjectTelemetryLog()
        for outcome: PermissionCoordinator.InjectOutcome in [
            .succeeded, .postedUnverified, .refused("changed"), .failedSilent
        ] {
            log.record(outcome: outcome, bundleID: "com.example.editor")
        }
        XCTAssertEqual(try XCTUnwrap(log.statsByBundle()["com.example.editor"]).successRatio, 0.25)
    }

    func testNormalTypeAheadAndSuppressedMissesAreSafeguards() {
        let log = InjectTelemetryLog()
        log.recordTypeAheadReplay(bundleID: "com.example.editor", characters: 1)
        log.recordSuppressedMissVerdict(bundleID: "com.example.editor")
        let report = log.summaryLines().joined(separator: "\n")
        XCTAssertTrue(report.contains("Delivery safeguards"), report)
        XCTAssertTrue(report.contains("type-ahead-replays=1(1 chars)"), report)
        XCTAssertFalse(report.contains("Duplicate risk"), report)
        XCTAssertFalse(report.contains("text written twice"), report)
    }

    func testAXFailureBurstIsCoalescedButRetriesAfterCooldown() {
        let checker = AXContextChecker()
        var calls = 0
        for _ in 0..<20 {
            XCTAssertEqual(checker.ensureManualAccessibility(pid: 42001, now: { 100 }) { _ in
                calls += 1
                return .cannotComplete
            }, .failed)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(checker.ensureManualAccessibility(pid: 42001, now: { 101 }) { _ in
            calls += 1
            return .success
        }, .activatedNow)
        XCTAssertEqual(calls, 2)
    }

    func testAXActivationInFlightDoesNotStartAnotherRequest() {
        let checker = AXContextChecker()
        var nestedCalls = 0
        XCTAssertEqual(checker.ensureManualAccessibility(pid: 42002, now: { 100 }) { _ in
            XCTAssertEqual(checker.ensureManualAccessibility(pid: 42002, now: { 100 }) { _ in
                nestedCalls += 1
                return .cannotComplete
            }, .failed)
            return .success
        }, .activatedNow)
        XCTAssertEqual(nestedCalls, 0)
    }

    func testAXCompletionCannotOverwriteARecycledProcessVerdict() {
        let checker = AXContextChecker()
        _ = checker.ensureManualAccessibility(pid: 42003, now: { 100 }) { _ in
            checker.forgetManualAccessibility(pid: 42003)
            XCTAssertEqual(checker.ensureManualAccessibility(pid: 42003, now: { 100 }) { _ in
                .attributeUnsupported
            }, .unsupported)
            return .success
        }
        XCTAssertEqual(checker.ensureManualAccessibility(pid: 42003, now: { 100 }) { _ in
            XCTFail("The replacement process has already been checked")
            return .cannotComplete
        }, .unsupported)
    }

    func testAXMemoHasBoundedProcessRetention() {
        let checker = AXContextChecker()
        for pid in 43000..<43300 {
            _ = checker.ensureManualAccessibility(pid: pid_t(pid), now: { 100 }) { _ in .success }
        }
        var calls = 0
        _ = checker.ensureManualAccessibility(pid: 43000, now: { 100 }) { _ in
            calls += 1
            return .attributeUnsupported
        }
        XCTAssertEqual(calls, 1, "The oldest process must be evicted from the bounded memo")
    }

    func testSecretCopiesDoNotRepeatedlyProbeAnUnreadableMasterKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = DiagnosticSecretTier()
        let account = UUID().uuidString
        XCTAssertEqual(tier.inner.set("retained-value", account: account), errSecSuccess)
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("secrets.enc"),
            tier: tier,
            diagnostics: tier.diagnostics
        )
        for _ in 0..<20 {
            XCTAssertEqual(store.value(account: account), "retained-value")
        }
        XCTAssertEqual(tier.masterReads, 1)
        XCTAssertEqual(tier.inner.value(account: account), "retained-value")
        XCTAssertEqual(tier.masterWrites, 0)
    }

    func testMalformedMasterKeyIsNeverReportedAsUsable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = InMemorySecretBackingStore()
        XCTAssertEqual(tier.set("invalid-key", account: ConsolidatedSecretBackingStore.masterKeyAccount),
                       errSecSuccess)
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("secrets.enc"),
            tier: tier, diagnostics: SecretAccessDiagnostics()
        )
        XCTAssertTrue(store.storageDescription().contains("MALFORMED"))
    }

    func testAXTerminationBypassesFailureCooldown() {
        let checker = AXContextChecker()
        _ = checker.ensureManualAccessibility(pid: 44001, now: { 100 }) { _ in .cannotComplete }
        checker.forgetManualAccessibility(pid: 44001)
        XCTAssertEqual(checker.ensureManualAccessibility(pid: 44001, now: { 100 }) { _ in
            .success
        }, .activatedNow)
    }

    func testAXInvalidClocksCannotPermanentlySuppressRecovery() {
        for timestamp in [Double.nan, .infinity, -.infinity, 99] {
            let checker = AXContextChecker()
            _ = checker.ensureManualAccessibility(pid: 44002, now: { 100 }) { _ in .cannotComplete }
            XCTAssertEqual(checker.ensureManualAccessibility(pid: 44002, now: { timestamp }) { _ in
                .success
            }, .activatedNow)
        }
    }

    func testAXInvalidPIDNeverCallsActivation() {
        for pid: pid_t in [0, -1, .min] {
            XCTAssertEqual(AXContextChecker().ensureManualAccessibility(pid: pid, now: { 100 }) { _ in
                XCTFail("Invalid process IDs must never reach AX")
                return .success
            }, .invalidPID)
        }
    }

    func testSecretConsolidationCooldownExpiresAndRecoversWithoutOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = DiagnosticSecretTier()
        let account = UUID().uuidString
        XCTAssertEqual(tier.inner.set("preserved", account: account), errSecSuccess)
        var now: TimeInterval = 100
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("secrets.enc"), tier: tier,
            diagnostics: tier.diagnostics, automaticConsolidationClock: { now }
        )
        XCTAssertEqual(store.value(account: account), "preserved")
        XCTAssertEqual(tier.diagnostics.lastRetrievalSucceeded(), true)
        XCTAssertEqual(tier.diagnostics.lastRead(), .failed(errSecAuthFailed),
                       "The infrastructure failure stays visible beside the successful retrieval")
        tier.masterReadable = true
        now = 104.999
        XCTAssertEqual(store.value(account: account), "preserved")
        XCTAssertEqual(tier.masterReads, 1)
        now = 105
        XCTAssertEqual(store.value(account: account), "preserved")
        XCTAssertEqual(tier.masterReads, 2)
        XCTAssertNil(tier.inner.value(account: account), "Verified consolidation removes the source")
        XCTAssertEqual(tier.masterWrites, 0)
        XCTAssertEqual(store.value(account: account), "preserved")
        XCTAssertNil(store.value(account: UUID().uuidString))
        XCTAssertEqual(tier.diagnostics.lastRetrievalSucceeded(), false)
    }

    func testExplicitSecretRepairBypassesAutomaticCooldown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = DiagnosticSecretTier()
        let account = UUID().uuidString
        XCTAssertEqual(tier.inner.set("preserved", account: account), errSecSuccess)
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("secrets.enc"), tier: tier,
            diagnostics: tier.diagnostics, automaticConsolidationClock: { 100 }
        )
        XCTAssertEqual(store.value(account: account), "preserved")
        tier.masterReadable = true
        XCTAssertEqual(store.consolidateIntoFile(), .init(moved: 1))
        XCTAssertEqual(store.value(account: account), "preserved")
        XCTAssertNil(tier.inner.value(account: account))
        XCTAssertEqual(tier.masterWrites, 0)
    }

    func testConsolidationSweepDoesNotRepeatAFailedMasterProbeToWarmIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = DiagnosticSecretTier()
        XCTAssertEqual(tier.inner.set("preserved", account: UUID().uuidString), errSecSuccess)
        let store = ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("secrets.enc"), tier: tier,
            diagnostics: tier.diagnostics
        )
        XCTAssertEqual(store.consolidateIntoFile(), .init(remaining: 1))
        XCTAssertEqual(tier.masterReads, 1)
    }

    func testSealedSecretsWithUnreadableKeyAreReportedUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-hardening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tier = DiagnosticSecretTier()
        tier.masterReadable = true
        let url = directory.appendingPathComponent("secrets.enc")
        let first = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: tier.diagnostics)
        let account = UUID().uuidString
        XCTAssertEqual(first.set("sealed-value", account: account), errSecSuccess)
        let archiveBefore = try Data(contentsOf: url)
        tier.masterReadable = false
        let reopened = ConsolidatedSecretBackingStore(fileURL: url, tier: tier, diagnostics: tier.diagnostics)
        XCTAssertNil(reopened.value(account: account))
        let report = reopened.storageDescription()
        XCTAssertTrue(report.contains("sealed secrets unavailable"), report)
        XCTAssertFalse(report.contains("keychain fallback in use"), report)
        XCTAssertEqual(try Data(contentsOf: url), archiveBefore)
        tier.masterReadable = true
        XCTAssertEqual(reopened.value(account: account), "sealed-value",
                       "Required decryption reads recover immediately")
        XCTAssertEqual(tier.masterWrites, 0)
    }

    func testReportDistinguishesRetrievalAndInfrastructureFailureAndNamesRepair() throws {
        let diagnostics = SecretAccessDiagnostics()
        diagnostics.record(.ok)
        diagnostics.recordRetrieval(succeeded: true)
        let suite = "diagnostic-hardening-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let report = DiagnosticReport.captureSecretLines(
            snippets: [], availability: .biometry("Touch ID"),
            defaults: defaults, accessDiagnostics: diagnostics,
            pendingMigrationCount: { 0 }, pendingAuthorizationCount: { 1 },
            storageDescription: {
                diagnostics.record(.failed(errSecAuthFailed))
                return "present but UNREADABLE"
            }
        ).joined(separator: "\n")
        XCTAssertTrue(report.contains("Secret retrieval: returned a value"), report)
        XCTAssertTrue(report.contains("Keychain last read: ok"), report)
        XCTAssertTrue(report.contains("Secrets pending migration: 0"), report)
        XCTAssertTrue(report.contains("including master key): 1"), report)
        XCTAssertTrue(report.contains("Preferences > Advanced > Repair Secret Storage"), report)
    }

    func testMixedRiskAndSafeguardsRetainBothAppsWithoutClaimingDuplication() {
        let log = InjectTelemetryLog()
        log.recordPasteRetry(bundleID: "com.example.risky")
        log.recordTypeAheadReplay(bundleID: "com.example.safe", characters: 2)
        let report = log.summaryLines().joined(separator: "\n")
        XCTAssertTrue(report.contains("Duplicate risk"), report)
        XCTAssertTrue(report.contains("Delivery safeguards"), report)
        XCTAssertTrue(report.contains("duplication unconfirmed"), report)
        XCTAssertTrue(report.contains("com.example.risky"), report)
        XCTAssertTrue(report.contains("com.example.safe"), report)
        XCTAssertFalse(report.contains("text written twice"), report)
    }
}

private final class DiagnosticSecretTier: SecretBackingStore {
    let inner = InMemorySecretBackingStore()
    let diagnostics = SecretAccessDiagnostics()
    var masterReads = 0
    var masterWrites = 0
    var masterReadable = false
    private let masterValue = Data(repeating: 7, count: 32).base64EncodedString()

    func set(_ value: String, account: String) -> OSStatus {
        if account == ConsolidatedSecretBackingStore.masterKeyAccount { masterWrites += 1 }
        return inner.set(value, account: account)
    }
    func value(account: String) -> String? {
        if account == ConsolidatedSecretBackingStore.masterKeyAccount {
            masterReads += 1
            diagnostics.record(masterReadable ? .ok : .failed(errSecAuthFailed))
            return masterReadable ? masterValue : nil
        }
        let value = inner.value(account: account)
        diagnostics.record(value == nil ? .failed(errSecItemNotFound) : .ok)
        return value
    }
    func contains(account: String) -> Bool {
        account == ConsolidatedSecretBackingStore.masterKeyAccount || inner.contains(account: account)
    }
    func delete(account: String) -> OSStatus { inner.delete(account: account) }
    func accounts() -> Set<String> {
        inner.accounts().union([ConsolidatedSecretBackingStore.masterKeyAccount])
    }
    func accountsNeedingAuthorization() -> [String] {
        masterReadable ? [] : [ConsolidatedSecretBackingStore.masterKeyAccount]
    }
}
