import LocalAuthentication
import XCTest
@testable import ExpanderEngine

/// The Touch ID gate in front of a secret.
///
/// Every branch here is one a developer's Mac cannot produce on demand — a wet finger, five failed
/// attempts, a Mac with no password set — so the authenticator is stubbed and the policy is pure.
/// What is *not* stubbed is the rule about when to ask at all, which is where a security control
/// quietly becomes decoration.
final class BiometricGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - When to ask

    func testFirstReadAlwaysAsks() {
        XCTAssertTrue(BiometricGate.needsAuthentication(lastSuccess: nil, now: now))
    }

    /// Copying two secrets in a row is one task. Prompting twice for it teaches people to approve
    /// without reading, which costs more than it buys.
    func testRecentSuccessIsReused() {
        let window = BiometricGate.reuseWindow
        XCTAssertFalse(
            BiometricGate.needsAuthentication(
                lastSuccess: now.addingTimeInterval(-window / 2), now: now
            )
        )
        XCTAssertTrue(
            BiometricGate.needsAuthentication(
                lastSuccess: now.addingTimeInterval(-window), now: now
            ),
            "Exactly one window later must ask again, or the limiter drifts open."
        )
        XCTAssertLessThanOrEqual(
            window, 120,
            "Past a couple of minutes this stops meaning 'the same task' and starts meaning "
                + "'authenticated this session', which is not what the user agreed to."
        )
    }

    /// A clock that jumps backwards (NTP correction, sleep/wake) must not open an unbounded reuse
    /// window. Failing safe here means asking again, which costs one touch.
    func testFutureTimestampAsksRatherThanTrusting() {
        XCTAssertTrue(
            BiometricGate.needsAuthentication(
                lastSuccess: now.addingTimeInterval(3600), now: now
            )
        )
    }

    // MARK: - Whether to gate at all

    func testOnlySecretsAreGated() {
        XCTAssertTrue(
            BiometricGate.shouldGate(
                isSecret: true, preferenceEnabled: true, availability: .biometry("Touch ID")
            )
        )
        XCTAssertFalse(
            BiometricGate.shouldGate(
                isSecret: false, preferenceEnabled: true, availability: .biometry("Touch ID")
            ),
            "An ordinary snippet behind a Touch ID prompt is friction with nothing behind it."
        )
        XCTAssertFalse(
            BiometricGate.shouldGate(
                isSecret: true, preferenceEnabled: false, availability: .biometry("Touch ID")
            )
        )
    }

    /// With no password and no biometrics there is nothing to check against. Refusing every read
    /// would lock the user out of their own snippets with no way to comply — the gate stands down
    /// instead, and Preferences says so in as many words.
    func testGateStandsDownWhenTheMachineCannotEvaluate() {
        XCTAssertFalse(
            BiometricGate.shouldGate(
                isSecret: true, preferenceEnabled: true, availability: .unavailable
            )
        )
        XCTAssertTrue(
            BiometricGate.shouldGate(
                isSecret: true, preferenceEnabled: true, availability: .passwordOnly
            ),
            "A Mac without Touch ID still has a login password, which is a real check."
        )
        XCTAssertFalse(BiometricGate.Availability.unavailable.canGate)
        XCTAssertTrue(BiometricGate.Availability.passwordOnly.canGate)
    }

    // MARK: - Preference default

    private func defaults() -> (UserDefaults, String) {
        let suite = "devtype.tests.secrets.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Defaults to on. The failure modes are not symmetric: an unwanted prompt costs one touch,
    /// a missing one costs a password to anyone who walks up to an unlocked Mac.
    func testRequireBiometryDefaultsOnWhereItCanWork() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }

        XCTAssertTrue(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID"))
        )
        XCTAssertTrue(
            SecretPreferences.requireBiometry(defaults: store, availability: .passwordOnly)
        )
        XCTAssertFalse(
            SecretPreferences.requireBiometry(defaults: store, availability: .unavailable),
            "Never report a gate as on when the machine cannot evaluate one — the switch would "
                + "be claiming a protection that is not there."
        )
    }

    func testExplicitOffIsHonoured() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }

        SecretPreferences.setRequireBiometry(false, defaults: store)
        XCTAssertFalse(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID"))
        )
        SecretPreferences.setRequireBiometry(true, defaults: store)
        XCTAssertTrue(
            SecretPreferences.requireBiometry(defaults: store, availability: .biometry("Touch ID"))
        )
    }

    // MARK: - The gate, end to end against a stub

    func testAuthorizationIsAskedOnceAndThenReusedUntilInvalidated() {
        let stub = StubBiometricAuthenticator(outcomes: [.authorized])
        var clock = now
        let gate = BiometricGate(authenticator: stub, clock: { clock })

        var outcomes: [BiometricGate.Outcome] = []
        gate.authorize(reason: "reveal “Work login”") { outcomes.append($0) }
        clock = now.addingTimeInterval(BiometricGate.reuseWindow / 2)
        gate.authorize(reason: "reveal “Work login”") { outcomes.append($0) }

        XCTAssertEqual(outcomes, [.authorized, .authorized])
        XCTAssertEqual(stub.evaluateCount, 1, "The second read fell inside the reuse window.")

        // Past the window, it asks again.
        clock = now.addingTimeInterval(BiometricGate.reuseWindow + 1)
        gate.authorize(reason: "reveal “Work login”") { outcomes.append($0) }
        XCTAssertEqual(stub.evaluateCount, 2)

        // Backgrounding the app drops the standing authorization immediately, window or not.
        gate.invalidate()
        gate.authorize(reason: "reveal “Work login”") { outcomes.append($0) }
        XCTAssertEqual(stub.evaluateCount, 3)
        XCTAssertEqual(stub.invalidateCount, 1)
    }

    /// A refusal must not be remembered as anything but a refusal — in particular it must not
    /// start a reuse window, or one cancelled prompt would wave the next read straight through.
    func testACancelDoesNotOpenAReuseWindow() {
        let stub = StubBiometricAuthenticator(outcomes: [.cancelled, .authorized])
        let gate = BiometricGate(authenticator: stub)

        var first: BiometricGate.Outcome?
        var second: BiometricGate.Outcome?
        gate.authorize(reason: "r") { first = $0 }
        gate.authorize(reason: "r") { second = $0 }

        XCTAssertEqual(first, .cancelled)
        XCTAssertEqual(second, .authorized)
        XCTAssertEqual(stub.evaluateCount, 2, "The cancelled attempt must not count as a success.")
    }

    func testFailureIsReportedWithTheSystemsOwnWording() {
        let stub = StubBiometricAuthenticator(outcomes: [.failed("Biometry is locked out.")])
        let gate = BiometricGate(authenticator: stub)

        var outcome: BiometricGate.Outcome?
        gate.authorize(reason: "r") { outcome = $0 }
        XCTAssertEqual(outcome, .failed("Biometry is locked out."))
    }

    /// The prompt string is rendered by macOS in a system dialog that anyone looking at the screen
    /// can read. It names the snippet; it must never carry the value.
    func testThePromptNamesTheSnippetOnly() {
        let stub = StubBiometricAuthenticator()
        let gate = BiometricGate(authenticator: stub)
        gate.authorize(reason: "reveal “Work login”") { _ in }

        XCTAssertEqual(stub.lastReason, "reveal “Work login”")
        XCTAssertFalse(stub.lastReason?.contains("hunter2") ?? true)
    }

    // MARK: - LAError mapping

    /// The split that matters is cancellation versus failure: a user who dismissed the prompt has
    /// already been told what happened, by themselves, and an error afterwards is noise.
    func testUserDrivenDismissalsAreCancellationsNotErrors() {
        for code in [LAError.userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback] {
            XCTAssertEqual(
                LocalAuthenticationAuthenticator.outcome(for: LAError(code)),
                .cancelled,
                "\(code) is the user's own action, not a condition to report."
            )
        }
    }

    func testConditionsTheUserMustFixAreReported() {
        for code in [LAError.biometryLockout, .passcodeNotSet, .biometryNotEnrolled] {
            guard case .failed = LocalAuthenticationAuthenticator.outcome(for: LAError(code)) else {
                return XCTFail("\(code) must be surfaced — the user cannot see it otherwise.")
            }
        }
        guard case .failed = LocalAuthenticationAuthenticator.outcome(for: nil) else {
            return XCTFail("A nil error with no success is still a failure, not an authorization.")
        }
    }

    // MARK: - No path around the gate

    /// Every surface that shows a secret must go through `SecretMenuFlow.resolve`. One that reads
    /// `SecretStore` directly gets the value *without the prompt*, silently — and the next surface
    /// added would copy whichever example it found first.
    func testNoUISurfaceReadsASecretDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for name in [
            "AppDelegate.swift",
            "SnippetManagerViewController.swift",
            "InlineSearchPanel.swift",
            "SnippetEditorSheet.swift",
            "ToastPanel.swift",
        ] {
            let url = root.appendingPathComponent("Sources/DevTypeApp/\(name)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            XCTAssertFalse(
                SourceContractTests.strippingComments(text).contains("SecretStore.shared.secret("),
                "\(name) reads a secret straight from the store, around the Touch ID gate."
            )
        }

        // The editor may ask *whether* a secret exists — that reveals nothing — but not what it is.
        let editor = try String(
            contentsOf: root.appendingPathComponent("Sources/DevTypeApp/SnippetEditorSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            editor.contains("SecretStore.shared.hasSecret(for:"),
            "The editor still needs the existence check to decide whether an untouched field "
                + "means 'keep what is stored'."
        )
    }
}
