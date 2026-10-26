import ExpanderEngine
import Foundation

public extension HarnessConstants {
    /// `userData` DevType stamps on every event it posts (`SyntheticEventMarker.magicUserData`). The
    /// chord observer keeps only events carrying it; a test pins this copy to the engine's.
    static let devTypeSyntheticMarker: Int64 = 0x534E_4950
}

/// Posts nothing: counts and keeps what would have been posted. The dry run's keyboard.
public final class RecordingKeyboard: KeyboardPort {
    public private(set) var events: [KeyEvent] = []
    public private(set) var releaseCalls = 0

    public init() {}

    public func post(_ event: KeyEvent) throws { events.append(event) }
    public func releaseHeldModifiers() { releaseCalls += 1 }
}

public enum Planner {
    /// How many key events a case would post, computed without touching a page or a keyboard.
    public static func plannedEventCount(_ testCase: HarnessCase, spec: HarnessSnippetSpec, hotkey: AIHotkey) -> Int {
        func count(_ text: String) -> Int {
            text.reduce(0) { $0 + ((try? KeyPlan.events(for: $1).count) ?? 0) }
        }
        return testCase.steps.reduce(0) { total, step in
            switch step {
            case .typeTrigger: return total + count(spec.trigger)
            case .typeLiteral(let text, _): return total + count(text)
            case .typeTriggerThenHold: return total + count(spec.trigger) + 1
            case .releaseModifier: return total + 1
            case .aiProofread: return total + hotkey.events.count + count("proofread") + 2
            case .reset, .focus, .pause, .recordSecureInput, .selectAll: return total
            }
        }
    }

    public static func describe(_ testCase: HarnessCase) -> String {
        "\(testCase.id): \(testCase.title) - \(testCase.proves)"
    }
}
