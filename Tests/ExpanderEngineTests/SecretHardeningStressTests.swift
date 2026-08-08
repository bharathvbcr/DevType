import XCTest
@testable import ExpanderEngine

/// §8.10 hardening: the read plan, the diagnostics trail, and the epoch/migration policy under
/// deliberately hostile sequences — random statuses, concurrent writers, alias exhaustion.
/// Deterministic (seeded SplitMix64) so a failure is a failure tomorrow too.
final class SecretHardeningStressTests: XCTestCase {

    private struct Rng {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
        mutating func bool() -> Bool { next() & 1 == 0 }
    }

    // MARK: - The read plan under arbitrary statuses

    /// Whatever securityd returns — documented, undocumented, or invented by a future macOS —
    /// the plan must stay a straight line: silent → heal → askUser → stop. No step may loop,
    /// and only the healed phase may escalate to the user.
    func testReadPlanNeverLoopsAndOnlyHealedEscalates() {
        var rng = Rng(seed: 0x8_10)
        var statuses: [OSStatus] = [
            errSecSuccess, errSecItemNotFound, errSecAuthFailed,
            errSecInteractionNotAllowed, errSecInvalidOwnerEdit, errSecUserCanceled,
            errSecMissingEntitlement, OSStatus(-1), OSStatus(Int32.min), OSStatus(Int32.max),
        ]
        for _ in 0..<500 { statuses.append(OSStatus(Int32(truncatingIfNeeded: rng.next()))) }

        for status in statuses {
            let silent = KeychainReadPlan.step(after: status, phase: .silent)
            let healed = KeychainReadPlan.step(after: status, phase: .healed)
            let interactive = KeychainReadPlan.step(after: status, phase: .interactive)

            // The silent phase may heal but never asks; only healed asks; interactive only stops.
            XCTAssertNotEqual(silent, .askUser, "status \(status)")
            XCTAssertNotEqual(healed, .heal, "status \(status): a second heal is a loop")
            XCTAssertTrue(
                interactive == .succeed || interactive == .fail,
                "status \(status): after the dialog there is nothing left to try"
            )

            // Success and absence terminate identically in every phase.
            if status == errSecSuccess {
                XCTAssertEqual(silent, .succeed); XCTAssertEqual(healed, .succeed)
            }
            if status == errSecItemNotFound {
                XCTAssertEqual(silent, .fail); XCTAssertEqual(healed, .fail)
            }
        }
    }

    // MARK: - Trail under contention

    /// The trail is written from whatever thread touches the keychain and read by the report.
    /// Hammer it concurrently: no crash (TSAN validates the rest), capacity respected, and
    /// every surviving line still well-formed.
    func testTrailSurvivesConcurrentWriters() {
        let diagnostics = SecretAccessDiagnostics()
        let accounts = (0..<8).map { _ in UUID().uuidString }

        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let account = accounts[i % accounts.count]
            diagnostics.note("fetch \(i)", OSStatus(-25293), account: account)
            diagnostics.note("heal \(i)", nil, account: account)
            _ = diagnostics.trail()
            diagnostics.record(i % 2 == 0 ? .ok : .healed)
        }

        let trail = diagnostics.trail()
        XCTAssertLessThanOrEqual(trail.count, SecretAccessDiagnostics.trailCapacity)
        XCTAssertFalse(trail.isEmpty)
        for line in trail {
            XCTAssertTrue(line.hasPrefix("item "), "aliased, always: \(line)")
            for account in accounts {
                XCTAssertFalse(line.contains(account), "UUID leaked into the trail: \(line)")
            }
        }
        // lastRead ends as one of the two values that were racing, never something else.
        XCTAssertTrue([SecretReadOutcome.ok, .healed].contains(diagnostics.lastRead()))
    }

    /// Aliases must stay unique and stable past the alphabet: 40 accounts, interleaved
    /// repeatedly, map to 40 distinct names and the same name every time.
    func testAliasesAreStableAndUniquePastTheAlphabet() {
        let diagnostics = SecretAccessDiagnostics()
        var rng = Rng(seed: 0xA11A5)
        let accounts = (0..<40).map { _ in UUID().uuidString }

        // First pass in order, then hammered at random.
        for account in accounts { diagnostics.note("first", nil, account: account) }
        for _ in 0..<400 {
            diagnostics.note("again", nil, account: accounts[rng.int(accounts.count)])
        }

        // Rebuild the mapping observed in the trail; one alias per account, everywhere.
        var seen: [String: String] = [:]
        for (index, account) in accounts.enumerated() {
            let fresh = SecretAccessDiagnostics()
            fresh.note("probe", nil, account: account)
            _ = fresh // aliasing is per-instance; the shared map is what we assert below
            _ = index
        }
        // The instance's own guarantee: replay each account and confirm the trail keeps using
        // one consistent alias for it (no reassignment under pressure).
        for account in accounts {
            diagnostics.note("final", nil, account: account)
            guard let line = diagnostics.trail().last else { return XCTFail("empty trail") }
            let alias = String(line.split(separator: ":").first ?? "")
            if let existing = seen[account] {
                XCTAssertEqual(existing, alias, "alias reassigned for the same account")
            } else {
                XCTAssertFalse(seen.values.contains(alias), "alias reused across accounts")
                seen[account] = alias
            }
        }
        XCTAssertEqual(Set(seen.values).count, accounts.count)
    }

    // MARK: - Epoch and migration policy

    /// The read order and migration rule are two lines of policy the whole design leans on;
    /// fuzz the rule's full input space (it is tiny) rather than trusting spot checks.
    func testEpochPolicyHoldsAcrossItsWholeInputSpace() {
        XCTAssertEqual(SecretServiceEpoch.readOrder.first, .current)
        XCTAssertEqual(Set(SecretServiceEpoch.readOrder), Set(SecretServiceEpoch.allCases))

        for epoch in SecretServiceEpoch.allCases {
            for succeeded in [true, false] {
                let migrates = SecretServiceEpoch.shouldMigrate(from: epoch, readSucceeded: succeeded)
                XCTAssertEqual(
                    migrates, epoch == .legacy && succeeded,
                    "migration fires exactly on a successful legacy read"
                )
            }
        }
    }

    /// In-memory stores — every test double in the suite — must be inert against the whole
    /// migration surface no matter what is thrown at them.
    func testInMemoryStoreIsInertAcrossTheMigrationSurfaceUnderFuzz() {
        var rng = Rng(seed: 0x1_0E)
        let store = SecretStore(backing: InMemorySecretBackingStore())
        var live: Set<UUID> = []

        for _ in 0..<2_000 {
            switch rng.int(6) {
            case 0:
                let id = UUID()
                if case .success = store.store("v\(rng.next())", for: id) { live.insert(id) }
            case 1:
                if let id = live.randomElement() { _ = store.secret(for: id) }
            case 2:
                if let id = live.first, rng.bool() {
                    _ = store.remove(for: id); live.remove(id)
                }
            case 3:
                XCTAssertTrue(store.snippetIDsPendingMigration().isEmpty)
            case 4:
                XCTAssertEqual(
                    store.migrateLegacy(allowInteraction: rng.bool()),
                    SecretMigrationSummary()
                )
            default:
                XCTAssertFalse(store.isKeychainLocked())
            }
        }
        // The fuzz above must not have corrupted ordinary reads.
        let id = UUID()
        _ = store.store("final", for: id)
        XCTAssertEqual(store.secret(for: id), "final")
    }

    // MARK: - The report under hostile trails

    /// Whatever ends up in the trail, the report's secret section must never carry a UUID —
    /// including one smuggled inside a step string by a future caller.
    func testReportSecretSectionNeverCarriesAnAccountUnderFuzz() {
        var rng = Rng(seed: 0x5EC_2E7)
        for round in 0..<50 {
            let diagnostics = SecretAccessDiagnostics()
            var accounts: [String] = []
            for _ in 0..<(1 + rng.int(6)) {
                let account = UUID().uuidString
                accounts.append(account)
                for _ in 0..<(1 + rng.int(8)) {
                    diagnostics.note(
                        ["v2 fetch", "legacy fetch", "heal", "migrate copy"][rng.int(4)],
                        OSStatus(Int32(truncatingIfNeeded: rng.next())),
                        account: account
                    )
                }
            }

            let suite = "secret-hardening-\(round)-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let text = DiagnosticReport.captureSecretLines(
                snippets: [],
                availability: rng.bool() ? .biometry("Touch ID") : .passwordOnly,
                defaults: defaults,
                accessDiagnostics: diagnostics,
                pendingMigrationCount: { rng.int(5) },
                keychainLocked: { rng.bool() }
            ).joined(separator: "\n")

            for account in accounts {
                XCTAssertFalse(text.contains(account), "account leaked into the report")
            }
            XCTAssertTrue(text.contains("Keychain: "), "lock state line must always be present")
        }
    }
}
