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
