import XCTest
@testable import ExpanderEngine

/// Switching the secret requirement **off** is itself a protected action.
///
/// The gate in front of a secret read was never the whole control: the switch that turns that
/// gate off sat behind nothing at all, in two different places. Someone at an unlocked Mac
/// could flip it and copy every stored password without ever being asked who they were, which
/// is the exact threat the feature exists for.
final class SecretPreferenceDowngradeTests: XCTestCase {

    private func defaults() -> (UserDefaults, String) {
        let suite = "devtype.tests.secrets.downgrade.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func gate(
        _ outcomes: [BiometricGate.Outcome],
        availability: BiometricGate.Availability = .biometry("Touch ID")
    ) -> (BiometricGate, StubBiometricAuthenticator) {
        let stub = StubBiometricAuthenticator(availability: availability, outcomes: outcomes)
        return (BiometricGate(authenticator: stub), stub)
    }

    @discardableResult
    private func request(
        _ enabled: Bool,
        gate: BiometricGate,
        defaults store: UserDefaults,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let done = expectation(description: "policy change settled")
        var inForce: Bool?
        SecretPreferences.requestRequireBiometry(enabled, defaults: store, gate: gate) { result in
            inForce = result
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        guard let inForce else {
            XCTFail("completion never ran", file: file, line: line)
            return true
        }
        return inForce
    }

    // MARK: - The downgrade that used to be free

    func testCancelledDowngradeLeavesTheRequirementOn() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, stub) = gate([.cancelled])

        let inForce = request(false, gate: gate, defaults: store)

        XCTAssertEqual(stub.evaluateCount, 1, "the user must be asked before the gate comes off")
        XCTAssertTrue(inForce, "a declined downgrade must report the requirement still standing")
        XCTAssertTrue(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID")),
            "cancelling the check must not write the downgrade"
        )
    }

    func testFailedDowngradeLeavesTheRequirementOn() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, stub) = gate([.failed("biometry lockout")])

        let inForce = request(false, gate: gate, defaults: store)

        XCTAssertEqual(stub.evaluateCount, 1)
        XCTAssertTrue(inForce)
        XCTAssertTrue(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID"))
        )
    }

    /// The point of the control is that it still works when the user *does* prove who they are.
    func testAuthorizedDowngradeApplies() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, stub) = gate([.authorized])

        let inForce = request(false, gate: gate, defaults: store)

        XCTAssertEqual(stub.evaluateCount, 1)
        XCTAssertFalse(inForce)
        XCTAssertFalse(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID"))
        )
    }

    /// A declined downgrade is not cosmetic: the next read has to still be gated.
    func testDeclinedDowngradeStillGatesTheNextRead() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, _) = gate([.cancelled])

        request(false, gate: gate, defaults: store)

        XCTAssertTrue(
            BiometricGate.shouldGate(
                isSecret: true,
                preferenceEnabled: SecretPreferences.requireBiometry(
                    defaults: store,
                    availability: .biometry("Touch ID")
                ),
                availability: .biometry("Touch ID")
            )
        )
    }

    /// A check from up to 30 seconds ago is good enough to copy a second secret. It is not good
    /// enough to remove the gate — that would spend the user's own last unlock on switching off
    /// the thing it unlocked.
    func testDowngradeDoesNotReuseAStandingAuthorization() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, stub) = gate([.authorized, .cancelled])

        // A read authorizes, exactly as copying a secret would.
        let read = expectation(description: "read authorized")
        gate.authorize(reason: "reveal") { outcome in
            XCTAssertEqual(outcome, .authorized)
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
        XCTAssertEqual(stub.evaluateCount, 1)

        let inForce = request(false, gate: gate, defaults: store)

        XCTAssertEqual(stub.evaluateCount, 2, "the downgrade must ask again, not ride the window")
        XCTAssertTrue(inForce)
        XCTAssertTrue(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID"))
        )
    }

    // MARK: - The direction that is always safe

    func testEnablingTheRequirementNeedsNoAuthentication() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        SecretPreferences.setRequireBiometry(false, defaults: store)
        let (gate, stub) = gate([.cancelled])

        let inForce = request(true, gate: gate, defaults: store)

        XCTAssertEqual(stub.evaluateCount, 0, "adding a check is never worth a prompt")
        XCTAssertTrue(inForce)
    }

    /// Re-affirming a requirement that is already on is not a downgrade either.
    func testReapplyingTheCurrentValueDoesNotPrompt() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, stub) = gate([.cancelled])

        XCTAssertTrue(request(true, gate: gate, defaults: store))
        XCTAssertEqual(stub.evaluateCount, 0)
    }

    /// With no password set there is nothing to prove with, and refusing the write would strand
    /// the preference. `requireBiometry` already reports false for such a machine.
    func testMachineThatCannotEvaluateAPolicyAppliesWithoutPrompting() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let (gate, stub) = gate([.cancelled], availability: .unavailable)

        let inForce = request(false, gate: gate, defaults: store)

        XCTAssertEqual(stub.evaluateCount, 0)
        XCTAssertFalse(inForce)
    }

    // MARK: - Pure policy

    func testOnlyTheWeakeningDirectionNeedsAuthorization() {
        let usable = BiometricGate.Availability.biometry("Touch ID")
        XCTAssertTrue(SecretPreferences.downgradeNeedsAuthorization(from: true, to: false, availability: usable))
        XCTAssertFalse(SecretPreferences.downgradeNeedsAuthorization(from: false, to: true, availability: usable))
        XCTAssertFalse(SecretPreferences.downgradeNeedsAuthorization(from: true, to: true, availability: usable))
        XCTAssertFalse(SecretPreferences.downgradeNeedsAuthorization(from: false, to: false, availability: usable))
        XCTAssertTrue(SecretPreferences.downgradeNeedsAuthorization(from: true, to: false, availability: .passwordOnly))
        XCTAssertFalse(
            SecretPreferences.downgradeNeedsAuthorization(from: true, to: false, availability: .unavailable),
            "nothing to prove with, and nothing being protected"
        )
    }
}
