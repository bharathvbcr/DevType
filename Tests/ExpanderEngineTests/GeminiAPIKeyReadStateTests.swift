import Foundation
import Security
import XCTest
@testable import ExpanderEngine

final class GeminiAPIKeyReadStateTests: XCTestCase {
    func testMissingItemIsDistinctFromAnUnavailableKeychain() {
        let missing = GeminiAPIKeyStore.readState(copyMatching: { _, _ in errSecItemNotFound })
        let locked = GeminiAPIKeyStore.readState(copyMatching: { _, _ in errSecInteractionNotAllowed })

        XCTAssertEqual(missing, .missing)
        XCTAssertEqual(locked, .unavailable(.keychainStatus(errSecInteractionNotAllowed)))
    }

    func testSuccessfulReadRequiresUTF8Data() {
        let valid = GeminiAPIKeyStore.readState { _, output in
            output?.pointee = Data("secret-key".utf8) as CFData
            return errSecSuccess
        }
        let invalid = GeminiAPIKeyStore.readState { _, output in
            output?.pointee = Data([0xff, 0xfe]) as CFData
            return errSecSuccess
        }
        let wrongType = GeminiAPIKeyStore.readState { _, output in
            output?.pointee = "not data" as CFString
            return errSecSuccess
        }

        XCTAssertEqual(valid, .available("secret-key"))
        XCTAssertEqual(invalid, .unavailable(.invalidData))
        XCTAssertEqual(wrongType, .unavailable(.invalidData))
    }

    func testFreshInstallDefaultsToAppleSpeech() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: VoicePreferences.transcriptionEngineKey)
        defaults.removeObject(forKey: VoicePreferences.transcriptionEngineKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: VoicePreferences.transcriptionEngineKey)
            } else {
                defaults.removeObject(forKey: VoicePreferences.transcriptionEngineKey)
            }
        }

        XCTAssertEqual(VoicePreferences.transcriptionEngine, .appleSpeech)
    }

    func testEffectiveEnginePreservesExplicitGeminiSelectionForEveryCredentialState() {
        let states: [GeminiAPIKeyStore.ReadState] = [
            .missing,
            .available(""),
            .available("key"),
            .unavailable(.keychainStatus(errSecInteractionNotAllowed)),
            .unavailable(.invalidData),
        ]
        for state in states {
            XCTAssertEqual(
                VoicePreferences.effectiveEngine(preferred: .gemini, keyState: state),
                .gemini,
                "Credential state \(state) must not silently change the selected provider"
            )
        }

        XCTAssertEqual(
            VoicePreferences.effectiveEngine(preferred: .whisperLocal, keyState: .missing),
            .whisperLocal
        )
    }
}
