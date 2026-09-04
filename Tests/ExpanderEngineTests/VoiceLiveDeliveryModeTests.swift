import XCTest
@testable import ExpanderEngine

/// Cover for the setting that decides what happens to your document *while* you are speaking.
///
/// Recognizing and typing used to be one boolean, which meant the middle option did not exist:
/// turning off progressive typing also turned off the recognizer, so the HUD went silent too.
/// The three modes separate "show me that it heard me" from "rewrite my document as I talk".
final class VoiceLiveDeliveryModeTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        VoicePreferences.resetAllForTesting()
    }

    // MARK: - Semantics

    func testOnlyTypeAsYouSpeakWritesToTheDocumentWhileSpeaking() {
        XCTAssertTrue(VoicePreferences.LiveDeliveryMode.typeAsYouSpeak.typesWhileSpeaking)
        XCTAssertFalse(VoicePreferences.LiveDeliveryMode.previewInHUD.typesWhileSpeaking)
        XCTAssertFalse(VoicePreferences.LiveDeliveryMode.insertAtEnd.typesWhileSpeaking)
    }

    func testPreviewStillNeedsTheLiveRecognizer() {
        XCTAssertTrue(VoicePreferences.LiveDeliveryMode.typeAsYouSpeak.usesLiveRecognition)
        XCTAssertTrue(
            VoicePreferences.LiveDeliveryMode.previewInHUD.usesLiveRecognition,
            "A bubble with no recognizer behind it has nothing to show"
        )
        XCTAssertFalse(VoicePreferences.LiveDeliveryMode.insertAtEnd.usesLiveRecognition)
    }

    func testEveryModeHasItsOwnLocalizationKey() {
        let keys = VoicePreferences.LiveDeliveryMode.allCases.map(\.localizationKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertFalse(
                LocalizationManager.shared.s(key).isEmpty,
                "Missing copy for \(key)"
            )
            XCTAssertNotEqual(
                LocalizationManager.shared.s(key), key,
                "Untranslated key surfaced to the user: \(key)"
            )
        }
    }

    // MARK: - Persistence and migration

    func testDefaultsToTypingAsYouSpeak() {
        XCTAssertEqual(VoicePreferences.liveDeliveryMode, .typeAsYouSpeak)
    }

    func testModeRoundTrips() {
        for mode in VoicePreferences.LiveDeliveryMode.allCases {
            VoicePreferences.liveDeliveryMode = mode
            XCTAssertEqual(VoicePreferences.liveDeliveryMode, mode)
        }
    }

    /// A user who had already switched progressive typing off must keep exactly the behaviour
    /// they chose — no live recognition — rather than silently acquiring a preview.
    func testMigratesTheLegacyBooleanWithoutChangingBehaviour() {
        VoicePreferences.resetAllForTesting()
        UserDefaults.standard.set(false, forKey: VoicePreferences.realTimeTypingKey)
        XCTAssertEqual(VoicePreferences.liveDeliveryMode, .insertAtEnd)

        VoicePreferences.resetAllForTesting()
        UserDefaults.standard.set(true, forKey: VoicePreferences.realTimeTypingKey)
        XCTAssertEqual(VoicePreferences.liveDeliveryMode, .typeAsYouSpeak)
    }

    func testAnExplicitModeWinsOverTheLegacyBoolean() {
        UserDefaults.standard.set(true, forKey: VoicePreferences.realTimeTypingKey)
        VoicePreferences.liveDeliveryMode = .previewInHUD

        XCTAssertEqual(VoicePreferences.liveDeliveryMode, .previewInHUD)
    }

    func testTheLegacyBooleanIsKeptInStepSoItCannotContradictTheMode() {
        VoicePreferences.liveDeliveryMode = .previewInHUD
        XCTAssertFalse(UserDefaults.standard.bool(forKey: VoicePreferences.realTimeTypingKey))
        XCTAssertFalse(VoicePreferences.isRealTimeTypingEnabled)

        VoicePreferences.liveDeliveryMode = .typeAsYouSpeak
        XCTAssertTrue(UserDefaults.standard.bool(forKey: VoicePreferences.realTimeTypingKey))
        XCTAssertTrue(VoicePreferences.isRealTimeTypingEnabled)
    }

    // MARK: - Permission interaction

    /// Preview mode needs the same Apple Speech grant typing does, so it must not be treated
    /// as "no live recognition wanted" when deciding whether to ask for it.
    func testPreviewModeRequestsTheSpeechGrantJustAsTypingDoes() {
        for engine in [TranscriptionEngine.gemini, .whisperLocal] {
            XCTAssertEqual(
                VoicePermissionPolicy.decision(
                    engine: engine,
                    liveRecognitionRequested: VoicePreferences.LiveDeliveryMode
                        .previewInHUD.usesLiveRecognition,
                    speechStatus: .notDetermined
                ),
                .requestAuthorization
            )
            XCTAssertEqual(
                VoicePermissionPolicy.decision(
                    engine: engine,
                    liveRecognitionRequested: VoicePreferences.LiveDeliveryMode
                        .insertAtEnd.usesLiveRecognition,
                    speechStatus: .notDetermined
                ),
                .proceed(enableLiveRecognition: false),
                "insertAtEnd needs no preview, so it must not prompt for one"
            )
        }
    }

    func testADeniedGrantStillDegradesPreviewRatherThanBlockingAnIndependentProvider() {
        XCTAssertEqual(
            VoicePermissionPolicy.decision(
                engine: .whisperLocal,
                liveRecognitionRequested: VoicePreferences.LiveDeliveryMode
                    .previewInHUD.usesLiveRecognition,
                speechStatus: .denied
            ),
            .proceed(enableLiveRecognition: false)
        )
    }
}
