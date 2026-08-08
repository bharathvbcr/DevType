import XCTest
@testable import ExpanderEngine

/// §8.10: the file-based keychain's partition list pins a self-signed app's access to one
/// build's CDHash, so every rebuild turned into a login-password dialog that "Always Allow"
/// could never satisfy. The fix is a silent metadata-touch that re-partitions the item —
/// legitimate because it is gated by the same cert-pinned ACL entry as the read itself.
///
/// The keychain half of this is empirical (probe binaries, signed and rebuilt, against the real
/// login keychain — see the commit message); what lives here is the pure policy those probes
/// justified: the retry plan, the tombstone rules, and the diagnostic wording.
final class KeychainPartitionHealTests: XCTestCase {

    // MARK: - The read plan

    func testSuccessStopsInEveryPhase() {
        for phase in [KeychainReadPlan.Phase.silent, .healed, .interactive] {
            XCTAssertEqual(KeychainReadPlan.step(after: errSecSuccess, phase: phase), .succeed)
        }
    }

    func testAbsentItemIsNeverHealedOrPromptedFor() {
        for phase in [KeychainReadPlan.Phase.silent, .healed, .interactive] {
            XCTAssertEqual(
                KeychainReadPlan.step(after: errSecItemNotFound, phase: phase), .fail,
                "No amount of healing or prompting invents an item."
            )
        }
    }

    func testPartitionMismatchHealsFirst() {
        // errSecAuthFailed is what a partition mismatch returns with UI suppressed — measured.
        XCTAssertEqual(KeychainReadPlan.step(after: errSecAuthFailed, phase: .silent), .heal)
    }

    func testFailureAfterHealEscalatesToTheUserExactlyOnce() {
        XCTAssertEqual(KeychainReadPlan.step(after: errSecAuthFailed, phase: .healed), .askUser)
        XCTAssertEqual(
            KeychainReadPlan.step(after: errSecAuthFailed, phase: .interactive), .fail,
            "The interactive attempt is the last: a second dialog would be a prompt loop."
        )
    }

    func testUnexpectedStatusesFollowTheSameEscalation() {
        // Whatever the OS invents next, the plan stays: try healing, then ask, then stop.
        for status in [errSecInteractionNotAllowed, errSecInvalidOwnerEdit, OSStatus(-1)] {
            XCTAssertEqual(KeychainReadPlan.step(after: status, phase: .silent), .heal)
            XCTAssertEqual(KeychainReadPlan.step(after: status, phase: .healed), .askUser)
            XCTAssertEqual(KeychainReadPlan.step(after: status, phase: .interactive), .fail)
        }
    }

    // MARK: - Service epochs

    func testCurrentServiceIsAlwaysConsultedFirst() {
        XCTAssertEqual(
            SecretServiceEpoch.readOrder, [.current, .legacy],
            "A migrated secret must never be shadowed by its legacy husk."
        )
    }

    func testTheTwoServicesAreDistinctAndLegacyKeepsItsHistoricName() {
        XCTAssertEqual(SecretServiceEpoch.legacy.service, "com.devtype.app.secret",
                       "Renaming the legacy service would orphan every existing secret.")
        XCTAssertEqual(SecretServiceEpoch.current.service, "com.devtype.app.secret.v2")
        XCTAssertNotEqual(SecretServiceEpoch.legacy.service, SecretServiceEpoch.current.service)
    }

    func testOnlyASuccessfulLegacyReadTriggersMigration() {
        XCTAssertTrue(SecretServiceEpoch.shouldMigrate(from: .legacy, readSucceeded: true))
        XCTAssertFalse(
            SecretServiceEpoch.shouldMigrate(from: .legacy, readSucceeded: false),
            "Migrating without the value would write nothing and destroy the original."
        )
        XCTAssertFalse(
            SecretServiceEpoch.shouldMigrate(from: .current, readSucceeded: true),
            "Current-epoch items are already owned by the stable identity."
        )
    }

    // MARK: - Tombstones

    func testTombstoneIsRecognisedOnlyByItsExactMarker() {
        XCTAssertTrue(KeychainPartitionPolicy.isTombstone(
            description: KeychainPartitionPolicy.tombstoneDescription
        ))
        XCTAssertFalse(KeychainPartitionPolicy.isTombstone(
            description: KeychainPartitionPolicy.liveDescription
        ))
        XCTAssertFalse(KeychainPartitionPolicy.isTombstone(description: nil))
        XCTAssertFalse(KeychainPartitionPolicy.isTombstone(description: ""))
    }

    func testTombstoneValueIsNonEmpty() {
        // SecItemUpdate silently ignores an empty kSecValueData, leaving the secret intact —
        // measured. An empty placeholder here would turn "destroy" into a silent no-op.
        XCTAssertFalse(KeychainPartitionPolicy.tombstoneValue.isEmpty)
    }

    func testLiveAndTombstoneMarkersAreDistinct() {
        XCTAssertNotEqual(
            KeychainPartitionPolicy.liveDescription,
            KeychainPartitionPolicy.tombstoneDescription,
            "A resurrected secret must stop reading as a husk."
        )
    }

    // MARK: - Diagnostics

    func testOutcomeRecorderKeepsTheLatestRead() {
        let diagnostics = SecretAccessDiagnostics()
        XCTAssertEqual(diagnostics.lastRead(), .none)

        diagnostics.record(.healed)
        XCTAssertEqual(diagnostics.lastRead(), .healed)

        diagnostics.record(.failed(errSecAuthFailed))
        XCTAssertEqual(diagnostics.lastRead(), .failed(errSecAuthFailed))
    }

    func testOutcomeLabelsAreDistinctAndNameTheHeal() {
        let outcomes: [SecretReadOutcome] = [.none, .ok, .healed, .granted, .failed(-25293)]
        let labels = outcomes.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "Each outcome must read differently.")
        XCTAssertTrue(SecretReadOutcome.healed.label.contains("healed"))
        XCTAssertTrue(SecretReadOutcome.failed(-25293).label.contains("-25293"))
    }

    func testTrailAliasesAccountsAndNeverLeaksThem() {
        let diagnostics = SecretAccessDiagnostics()
        let uuid = UUID().uuidString
        diagnostics.note("legacy fetch", -25293, account: uuid)
        diagnostics.note("heal", nil, account: uuid)
        diagnostics.note("v2 fetch", 0, account: UUID().uuidString)

        let trail = diagnostics.trail()
        XCTAssertEqual(trail, [
            "item A: legacy fetch → -25293",
            "item A: heal",
            "item B: v2 fetch → 0",
        ])
        XCTAssertFalse(trail.joined().contains(uuid),
                       "The account is the snippet UUID; the trail is pasted into reports.")
    }

    func testTrailDropsOldestStepsPastCapacity() {
        let diagnostics = SecretAccessDiagnostics()
        for i in 0..<(SecretAccessDiagnostics.trailCapacity + 10) {
            diagnostics.note("step \(i)")
        }
        let trail = diagnostics.trail()
        XCTAssertEqual(trail.count, SecretAccessDiagnostics.trailCapacity)
        XCTAssertEqual(trail.first, "step 10", "Oldest steps fall off the front.")
        XCTAssertEqual(trail.last, "step \(SecretAccessDiagnostics.trailCapacity + 9)")
    }

    func testInMemoryStoresHaveNothingToMigrate() {
        let store = SecretStore(backing: InMemorySecretBackingStore())
        XCTAssertTrue(store.snippetIDsPendingMigration().isEmpty)
        XCTAssertEqual(store.migrateLegacy(allowInteraction: true), SecretMigrationSummary())
    }

    func testReportCarriesThePendingCountAndTrail() {
        let diagnostics = SecretAccessDiagnostics()
        diagnostics.note("legacy fetch", -25293, account: UUID().uuidString)

        let suite = "keychain-migration-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        let text = DiagnosticReport.captureSecretLines(
            snippets: [],
            availability: .biometry("Touch ID"),
            defaults: store,
            accessDiagnostics: diagnostics,
            pendingMigrationCount: { 2 }
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains("Secrets pending migration: 2"))
        XCTAssertTrue(text.contains("trail: item A: legacy fetch → -25293"),
                      "The trail is the log that turns 'it prompted again' into a diagnosis.")
    }

    func testReportSaysHowTheLastKeychainReadWent() {
        let diagnostics = SecretAccessDiagnostics()
        diagnostics.record(.healed)

        let suite = "keychain-heal-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }

        let text = DiagnosticReport.captureSecretLines(
            snippets: [],
            availability: .biometry("Touch ID"),
            defaults: store,
            accessDiagnostics: diagnostics
        ).joined(separator: "\n")

        XCTAssertTrue(
            text.contains("Keychain last read: ok (healed partition after rebuild)"),
            "The report must tell a healed rebuild apart from a real keychain refusal."
        )
    }
}
