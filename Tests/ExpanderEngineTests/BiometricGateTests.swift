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
    // MARK: - Which policy actually gets used

    /// The shipped bug, as one assertion. `.deviceOwnerAuthentication` means "biometry **or** the
    /// password", and macOS answers it with the password sheet — so a Mac with a working Touch ID
    /// sensor asked for a typed password every single time.
    func testBiometryIsAskedForWhenTheMacHasIt() {
        XCTAssertEqual(
            LocalAuthenticationAuthenticator.initialPolicy(for: .biometry("Touch ID")),
            .deviceOwnerAuthenticationWithBiometrics,
            "This is the policy that presents Touch ID. The other one presents a password field."
        )
        XCTAssertEqual(
            LocalAuthenticationAuthenticator.initialPolicy(for: .passwordOnly),
            .deviceOwnerAuthentication,
            "With no biometry there is nothing else to ask for."
        )
        XCTAssertEqual(
            LocalAuthenticationAuthenticator.initialPolicy(for: .unavailable),
            .deviceOwnerAuthentication
        )
    }

    /// The password must stay reachable — a wet finger should be an inconvenience, not a locked
    /// door — but only as a deliberate second step.
    func testOnlyBiometryDeadEndsEscalateToThePassword() {
        for code in [LAError.userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled] {
            XCTAssertTrue(
                LocalAuthenticationAuthenticator.shouldEscalateToPassword(after: LAError(code)),
                "\(code) means biometry cannot answer; the user needs the other route."
            )
        }
        for code in [LAError.userCancel, .appCancel, .systemCancel, .authenticationFailed] {
            XCTAssertFalse(
                LocalAuthenticationAuthenticator.shouldEscalateToPassword(after: LAError(code)),
                "\(code) is a dismissal or a retryable mis-read — macOS handles it in its own UI, "
                    + "and escalating would spring a password prompt the user never asked for."
            )
        }
        XCTAssertFalse(LocalAuthenticationAuthenticator.shouldEscalateToPassword(after: nil))
    }

    // MARK: - The escalation sequence, driven deterministically

    /// Records every policy the authenticator evaluates, so the *order* is assertable without a
    /// real sensor.
    private func recordingAuthenticator(
        availability: BiometricGate.Availability,
        results: [(Bool, Error?)]
    ) -> (LocalAuthenticationAuthenticator, () -> [LAPolicy]) {
        var scripted = results
        var seen: [LAPolicy] = []
        let authenticator = LocalAuthenticationAuthenticator(
            availabilityProbe: { availability },
            evaluator: { policy, _, _, completion in
                seen.append(policy)
                let next = scripted.isEmpty ? (false, nil) : scripted.removeFirst()
                completion(next.0, next.1)
            },
            fallbackTitle: { "Use Password…" }
        )
        return (authenticator, { seen })
    }

    func testTouchIDSucceedsWithoutEverAskingForAPassword() {
        let (authenticator, policies) = recordingAuthenticator(
            availability: .biometry("Touch ID"),
            results: [(true, nil)]
        )
        var outcome: BiometricGate.Outcome?
        authenticator.evaluate(reason: "r") { outcome = $0 }

        XCTAssertEqual(outcome, .authorized)
        XCTAssertEqual(
            policies(), [.deviceOwnerAuthenticationWithBiometrics],
            "A successful finger must not be followed by a password prompt."
        )
    }

    func testTappingUsePasswordFallsThroughToTheLoginPassword() {
        let (authenticator, policies) = recordingAuthenticator(
            availability: .biometry("Touch ID"),
            results: [(false, LAError(.userFallback)), (true, nil)]
        )
        var outcome: BiometricGate.Outcome?
        authenticator.evaluate(reason: "r") { outcome = $0 }

        XCTAssertEqual(outcome, .authorized)
        XCTAssertEqual(
            policies(),
            [.deviceOwnerAuthenticationWithBiometrics, .deviceOwnerAuthentication]
        )
    }

    func testLockoutFallsThroughRatherThanDeadEnding() {
        let (authenticator, policies) = recordingAuthenticator(
            availability: .biometry("Touch ID"),
            results: [(false, LAError(.biometryLockout)), (true, nil)]
        )
        var outcome: BiometricGate.Outcome?
        authenticator.evaluate(reason: "r") { outcome = $0 }

        XCTAssertEqual(outcome, .authorized)
        XCTAssertEqual(policies().count, 2)
    }

    /// A dismissal is the end of it. Escalating a cancel would mean the user says "no" and gets
    /// asked again in a different form, which is how a prompt becomes something people click
    /// through without reading.
    func testCancellingStopsThere() {
        let (authenticator, policies) = recordingAuthenticator(
            availability: .biometry("Touch ID"),
            results: [(false, LAError(.userCancel))]
        )
        var outcome: BiometricGate.Outcome?
        authenticator.evaluate(reason: "r") { outcome = $0 }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(policies(), [.deviceOwnerAuthenticationWithBiometrics])
    }

    /// One escalation, never a loop: the password attempt cannot escalate again.
    func testEscalationHappensAtMostOnce() {
        let (authenticator, policies) = recordingAuthenticator(
            availability: .biometry("Touch ID"),
            results: [(false, LAError(.userFallback)), (false, LAError(.userFallback))]
        )
        var outcome: BiometricGate.Outcome?
        authenticator.evaluate(reason: "r") { outcome = $0 }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(policies().count, 2, "A third prompt would be an escalation loop.")
    }

    /// A Mac with no sensor goes straight to the password and does not pretend otherwise.
    func testPasswordOnlyMacAsksOnce() {
        let (authenticator, policies) = recordingAuthenticator(
            availability: .passwordOnly,
            results: [(true, nil)]
        )
        var outcome: BiometricGate.Outcome?
        authenticator.evaluate(reason: "r") { outcome = $0 }

        XCTAssertEqual(outcome, .authorized)
        XCTAssertEqual(policies(), [.deviceOwnerAuthentication])
    }

    // MARK: - The diagnostic report

    /// "It asks for my password instead of Touch ID" was not diagnosable from the report at all:
    /// whether the gate is on, and whether this Mac can do biometry, are the two facts that
    /// separate a policy bug from a Mac with no enrolled finger.
    func testReportCarriesEnoughToDiagnoseAWrongPrompt() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }

        let lines = DiagnosticReport.captureSecretLines(
            snippets: [
                SnippetModel(title: "Work login", triggerKeyword: ";pw", replacementText: "", isSecret: true),
                SnippetModel(title: "Address", triggerKeyword: ";addr", replacementText: "1 Main St"),
            ],
            availability: .biometry("Touch ID"),
            defaults: store
        )
        let text = lines.joined(separator: "\n")

        XCTAssertTrue(text.contains("Secret snippets: 1"))
        XCTAssertTrue(text.contains("Biometry: available (Touch ID)"))
        XCTAssertTrue(text.contains("Require authentication: on"))
    }

    func testReportNamesTheMacsActualCapability() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }

        let passwordOnly = DiagnosticReport.captureSecretLines(
            snippets: [], availability: .passwordOnly, defaults: store
        ).joined(separator: "\n")
        XCTAssertTrue(passwordOnly.contains("password only"))

        let unavailable = DiagnosticReport.captureSecretLines(
            snippets: [], availability: .unavailable, defaults: store
        ).joined(separator: "\n")
        XCTAssertTrue(unavailable.contains("unavailable"))
        XCTAssertTrue(
            unavailable.contains("Require authentication: off"),
            "Never report a gate as on where the machine cannot evaluate one."
        )
    }

    /// The report is pasted into chat windows and issue trackers. A list of what someone keeps
    /// passwords *for* is worth protecting even when the passwords themselves are not in it.
    func testReportNeverNamesASecret() {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }

        let secret = SnippetModel(
            title: "Barclays business banking",
            triggerKeyword: ";bank",
            replacementText: "",
            isSecret: true
        )
        let text = DiagnosticReport.captureSecretLines(
            snippets: [secret], availability: .biometry("Touch ID"), defaults: store
        ).joined(separator: "\n")

        XCTAssertFalse(text.contains("Barclays"), "A title is a hint about what the value unlocks.")
        XCTAssertFalse(text.contains(";bank"))
        XCTAssertFalse(text.contains(secret.id.uuidString))
    }

}
