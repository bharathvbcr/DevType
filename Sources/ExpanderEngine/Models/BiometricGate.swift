import Foundation
import LocalAuthentication

/// Touch ID (or the login password) in front of a secret.
///
/// **What this is, and what it is not.** The stronger form of this feature is a keychain item
/// carrying `kSecAttrAccessControl` with a biometry flag, where the Secure Enclave itself refuses
/// to hand the value over without a matching finger. That form needs the *data protection*
/// keychain, and per Apple's TN3137 the data protection keychain "is only available to code that
/// can carry an entitlement" — a keychain access group established by code signing. DevType ships
/// without entitlements (which is also why `SecretStore` uses the file-based keychain), so that
/// door is shut until the signing setup changes.
///
/// What this gate does instead is check with `LocalAuthentication` before *DevType* reads the
/// value. That is a real defence against the threat that actually applies here — someone at your
/// unlocked Mac clicking Copy Secret while you are away from the desk — and it is not a defence
/// against code already running as you, which can call `SecItemCopyMatching` itself and never ask.
/// Saying so plainly in the UI matters more than the mechanism.
public final class BiometricGate {
    public static let shared = BiometricGate()

    /// How long a successful check stands before the next read asks again.
    ///
    /// Copying two secrets in a row is one task, and prompting twice for it trains people to
    /// approve without reading. Short enough that the answer does not survive walking away:
    /// anything longer starts to mean "authenticated once this session", which is not what the
    /// user agreed to when they turned this on.
    public static let reuseWindow: TimeInterval = 30

    /// What the machine can actually do, in the terms the UI needs.
    public enum Availability: Equatable {
        /// Touch ID (or another biometry) is enrolled and usable. Carries the localized name
        /// macOS uses for it, so the UI never hard-codes "Touch ID" on a Mac that says otherwise.
        case biometry(String)
        /// No usable biometry, but the login password can still gate the read.
        case passwordOnly
        /// Neither — no password set, or the policy cannot be evaluated at all.
        case unavailable

        public var canGate: Bool { self != .unavailable }
    }

    /// The result of asking, in the terms the *caller* needs: proceed, stay silent, or explain.
    public enum Outcome: Equatable {
        case authorized
        /// The user said no. Not an error — never show them a dialog about their own decision.
        case cancelled
        /// Something went wrong that the user has to know about (lockout, no passcode set).
        case failed(String)
    }

    private let authenticator: BiometricAuthenticating
    /// One clock for both halves of the reuse window.
    ///
    /// The first version took `now` as a parameter on the *check* but stamped the *record* with
    /// `Date()`, so the two disagreed the moment a caller supplied a clock — the window silently
    /// never applied. A single injected clock is the only shape where "recorded at" and "compared
    /// against" cannot drift apart.
    private let clock: () -> Date
    private let lock = UnfairLock()
    private var lastSuccess: Date?

    public init(
        authenticator: BiometricAuthenticating = LocalAuthenticationAuthenticator(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.clock = clock
    }

    // MARK: - Pure policy

    /// Does a read need a fresh check, given when the last one succeeded?
    ///
    /// A `nil` last-success always prompts. A timestamp in the *future* (clock moved backwards
    /// across an NTP correction or a sleep/wake) prompts too: an unbounded reuse window opened by
    /// a clock jump is exactly the kind of quiet failure that turns a security control into
    /// decoration.
    public static func needsAuthentication(
        lastSuccess: Date?,
        now: Date,
        window: TimeInterval = reuseWindow
    ) -> Bool {
        guard let lastSuccess else { return true }
        let elapsed = now.timeIntervalSince(lastSuccess)
        return elapsed < 0 || elapsed >= window
    }

    /// Pure policy: should this read be gated at all?
    ///
    /// Only secrets, only when the preference is on, and only when the machine can actually
    /// evaluate a policy. The last clause is not a loophole — with no password set there is
    /// nothing to check against, and refusing every read would lock the user out of their own
    /// snippets with no way to comply.
    public static func shouldGate(
        isSecret: Bool,
        preferenceEnabled: Bool,
        availability: Availability
    ) -> Bool {
        isSecret && preferenceEnabled && availability.canGate
    }

    // MARK: - Live

    public func availability() -> Availability {
        authenticator.availability()
    }

    /// Ask, unless a recent success still stands. Completion is always on the main queue.
    ///
    /// - Parameter reason: shown in the system prompt. Names the snippet, never the value.
    public func authorize(
        reason: String,
        completion: @escaping (Outcome) -> Void
    ) {
        lock.lock()
        let last = lastSuccess
        lock.unlock()

        guard Self.needsAuthentication(lastSuccess: last, now: clock()) else {
            DevTypeLog.inject.info("[Secret] auth reused (within \(Int(Self.reuseWindow), privacy: .public)s)")
            return dispatchToMain { completion(.authorized) }
        }

        authenticator.evaluate(reason: reason) { [weak self] outcome in
            if case .authorized = outcome, let self {
                // Stamped when the answer arrived, not when it was asked: a prompt the user left
                // sitting for a minute should not spend that minute of the window before it opens.
                self.lock.lock()
                self.lastSuccess = self.clock()
                self.lock.unlock()
            }
            // Privacy: the outcome, never the snippet's value; the reason string is already the
            // snippet's title, which the user just clicked.
            DevTypeLog.inject.info("[Secret] auth → \(outcome.logLabel, privacy: .public)")
            self?.dispatchToMain { completion(outcome) }
        }
    }

    /// Drop any standing authorization — used when the app resigns active, so returning to a
    /// machine someone else may have touched asks again.
    public func invalidate() {
        lock.lock()
        lastSuccess = nil
        lock.unlock()
        authenticator.invalidate()
    }

    private func dispatchToMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

public extension BiometricGate.Outcome {
    var logLabel: String {
        switch self {
        case .authorized: return "authorized"
        case .cancelled: return "cancelled"
        case .failed(let reason): return "failed(\(reason))"
        }
    }
}

// MARK: - Authenticator

/// The LocalAuthentication surface `BiometricGate` needs, behind a protocol so tests can drive
/// every branch — including the ones a developer's Mac cannot produce on demand, like biometry
/// lockout after five failed fingers.
public protocol BiometricAuthenticating: AnyObject {
    func availability() -> BiometricGate.Availability
    func evaluate(reason: String, completion: @escaping (BiometricGate.Outcome) -> Void)
    func invalidate()
}

public final class LocalAuthenticationAuthenticator: BiometricAuthenticating {
    /// One context, reused, so macOS can apply its own reuse rules on top of ours; replaced after
    /// `invalidate()` because an `LAContext` remembers its last successful evaluation.
    private var context = LAContext()
    private let lock = UnfairLock()

    public init() {}

    public func availability() -> BiometricGate.Availability {
        // A fresh context: `canEvaluatePolicy` caches, and a stale answer here would claim Touch
        // ID on a Mac where the user has since removed their fingerprints.
        let probe = LAContext()
        var error: NSError?

        if probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .biometry(Self.biometryName(probe))
        }
        // Biometry unavailable is not the end of it: `.deviceOwnerAuthentication` still gates on
        // the login password, which is the honest fallback on a Mac with no Touch ID.
        if probe.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return .passwordOnly
        }
        return .unavailable
    }

    public func evaluate(reason: String, completion: @escaping (BiometricGate.Outcome) -> Void) {
        lock.lock()
        let context = self.context
        lock.unlock()

        // `.deviceOwnerAuthentication` rather than `…WithBiometrics`: it prompts for Touch ID
        // first and falls back to the login password, so a wet finger or a Mac without a sensor
        // is an inconvenience rather than a locked door.
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if success { return completion(.authorized) }
            completion(Self.outcome(for: error))
        }
    }

    public func invalidate() {
        lock.lock()
        context.invalidate()
        context = LAContext()
        lock.unlock()
    }

    /// Map `LAError` to something the caller can act on.
    ///
    /// The split that matters is cancellation versus failure. A user who dismissed the prompt has
    /// already been told what happened — by themselves — and showing them an error afterwards is
    /// noise. Everything else is a condition they cannot see and may need to fix.
    static func outcome(for error: Error?) -> BiometricGate.Outcome {
        guard let error = error as? LAError else {
            return .failed(error?.localizedDescription ?? "unknown")
        }
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .authenticationFailed:
            // The finger did not match and macOS already said so in its own UI.
            return .cancelled
        case .userFallback:
            // Only reachable with a policy that has no password fallback of its own; treated as a
            // cancel so it cannot be mistaken for an authorization.
            return .cancelled
        default:
            return .failed(error.localizedDescription)
        }
    }

    private static func biometryName(_ context: LAContext) -> String {
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }
}

/// Scripted authenticator for tests. Never used by the app.
public final class StubBiometricAuthenticator: BiometricAuthenticating {
    public var stubbedAvailability: BiometricGate.Availability
    /// Outcomes handed out in order; the last one repeats once exhausted.
    public var scriptedOutcomes: [BiometricGate.Outcome]
    public private(set) var evaluateCount = 0
    public private(set) var invalidateCount = 0
    public private(set) var lastReason: String?

    public init(
        availability: BiometricGate.Availability = .biometry("Touch ID"),
        outcomes: [BiometricGate.Outcome] = [.authorized]
    ) {
        stubbedAvailability = availability
        scriptedOutcomes = outcomes
    }

    public func availability() -> BiometricGate.Availability { stubbedAvailability }

    public func evaluate(reason: String, completion: @escaping (BiometricGate.Outcome) -> Void) {
        lastReason = reason
        let outcome = scriptedOutcomes.count > 1
            ? scriptedOutcomes.removeFirst()
            : (scriptedOutcomes.first ?? .authorized)
        evaluateCount += 1
        completion(outcome)
    }

    public func invalidate() { invalidateCount += 1 }
}
