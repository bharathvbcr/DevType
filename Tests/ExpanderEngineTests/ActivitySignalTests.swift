import XCTest
@testable import ExpanderEngine

final class ActivitySignalTests: XCTestCase {
    private var loc: LocalizationManager!
    private var previousLanguageValue: Any?

    override func setUp() {
        super.setUp()
        previousLanguageValue = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
        loc = LocalizationManager()
        loc.language = .en
    }

    override func tearDown() {
        if let previousLanguageValue {
            UserDefaults.standard.set(previousLanguageValue, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        loc = nil
        super.tearDown()
    }

    func testEveryActionableSubsystemProducesATypedAction() {
        let cases: [(ActivitySignal, ActivityHistoryStore.EventCategory, ActivityHistoryStore.EventAction)] = [
            (.permissionState(
                snapshot: PermissionSnapshot(canListenTap: false, canUseAX: true, canPostEvents: true),
                tapRunning: false
            ), .general, .openPermissionRecovery),
            (.injectionRefused, .expansion, .openLab),
            (.injectionFailed, .expansion, .copyDiagnostics),
            (.secureInputChanged(active: true), .secureInput, .none),
            (.libraryIssue(.saveFailed, affectedCount: nil), .library, .openSnippetManager),
            (.importCompleted(added: 2, updated: 1, unchanged: 4, saved: true), .importExport, .openSnippetManager),
            (.importFailed, .importExport, .openSnippetManager),
            (.aiFailed, .ai, .openAIPreferences),
            (.voiceTerminal(VoiceTerminalDiagnostic(
                outcome: .failed,
                code: .failure(.requestTimeout),
                stage: .recognition,
                provider: .whisperCpp,
                locality: .localNetwork,
                recoverability: .retryAfterDelay
            )), .voice, .openVoicePreferences),
            (.voiceRecovery(
                sessionID: VoiceSessionID(rawValue: UUID(uuidString: "14F6724A-7549-4E24-AD5D-468B811C88F1")!),
                characterCount: 42,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ), .voice, .reviewRecoveredVoice),
            (.hotkeyRegistrationFailed(status: -9876), .hotkey, .openHotkeyPreferences)
        ]

        for (signal, category, action) in cases {
            let descriptor = signal.descriptor(localization: loc)
            XCTAssertEqual(descriptor.category, category, "Wrong category for \(signal)")
            XCTAssertEqual(descriptor.action, action, "Wrong action for \(signal)")
            XCTAssertFalse(descriptor.title.isEmpty)
            XCTAssertFalse(descriptor.details.isEmpty)
            XCTAssertFalse(descriptor.deduplicationKey.isEmpty)
        }
    }

    func testPermissionSignalCarriesOnlyCapabilityState() {
        let sentinel = "never-store-focused-text-7F41"
        let descriptor = ActivitySignal.permissionState(
            snapshot: PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: false),
            tapRunning: false
        ).descriptor(localization: loc)

        XCTAssertTrue(descriptor.details.contains("Accessibility"))
        XCTAssertTrue(descriptor.details.contains("Input Monitoring"))
        XCTAssertTrue(descriptor.details.contains("Post Events"))
        XCTAssertFalse(descriptor.title.contains(sentinel))
        XCTAssertFalse(descriptor.details.contains(sentinel))
    }

    func testFailureSignalsNeverAcceptOrPersistFreeFormPayloads() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("activity.json")
        let store = ActivityHistoryStore(fileURL: url)

        XCTAssertEqual(store.record(.aiFailed, localization: loc), .persisted)
        XCTAssertEqual(
            store.record(
                .voiceTerminal(VoiceTerminalDiagnostic(
                    outcome: .failed,
                    code: .failure(.secureInputActive),
                    stage: .delivery,
                    provider: .textDelivery,
                    locality: .onDevice,
                    recoverability: .userActionRequired
                )),
                localization: loc
            ),
            .persisted
        )

        let encoded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("selected text"))
        XCTAssertTrue(encoded.contains("secureInputActive"))

        let reloaded = ActivityHistoryStore(fileURL: url).recentEvents()
        let voiceEvent = try XCTUnwrap(reloaded.first(where: { $0.category == .voice }))
        guard case .voiceTerminal(let diagnostic) = voiceEvent.typedSignal else {
            return XCTFail("Expected the persisted voice event to retain its typed payload")
        }
        XCTAssertEqual(diagnostic.provider, .textDelivery)
        XCTAssertEqual(diagnostic.locality, .onDevice)
        XCTAssertEqual(diagnostic.recoverability, .userActionRequired)
        let details = voiceEvent.presentation(localization: loc).details
        XCTAssertTrue(details.contains("provider=textDelivery"))
        XCTAssertTrue(details.contains("locality=onDevice"))
        XCTAssertTrue(details.contains("recoverability=userActionRequired"))
    }

    func testCancellationAndSupersessionAreNotPresentedAsFailures() {
        let cancelled = ActivitySignal.voiceTerminal(VoiceTerminalDiagnostic(
            outcome: .cancelled,
            code: .cancelled,
            stage: .audioCapture,
            provider: .audioCapture,
            locality: .onDevice,
            recoverability: .notApplicable
        )).descriptor(localization: loc)
        let superseded = ActivitySignal.voiceTerminal(VoiceTerminalDiagnostic(
            outcome: .superseded,
            code: .superseded,
            stage: .recognition,
            provider: .appleSpeech,
            locality: .onDevice,
            recoverability: .retryImmediately
        )).descriptor(localization: loc)

        XCTAssertFalse(cancelled.title.contains("Failed"))
        XCTAssertFalse(superseded.title.contains("Failed"))
        XCTAssertEqual(cancelled.action, .none)
        XCTAssertEqual(superseded.action, .none)
        XCTAssertTrue(cancelled.details.contains("provider=audioCapture"))
        XCTAssertTrue(superseded.details.contains("code=sessionSuperseded"))
    }

    func testRecoveredVoiceSignalPersistsOnlyOpaqueMetadataAndRendersInCurrentLanguage() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("activity.json")
        let sessionID = VoiceSessionID(
            rawValue: UUID(uuidString: "14F6724A-7549-4E24-AD5D-468B811C88F1")!
        )
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let signal = ActivitySignal.voiceRecovery(
            sessionID: sessionID,
            characterCount: 37,
            recordedAt: recordedAt
        )
        let event = ActivityHistoryStore.ActivityEvent(
            timestamp: recordedAt,
            signal: signal,
            localization: loc
        )
        let store = ActivityHistoryStore(fileURL: url)

        XCTAssertEqual(store.recordBatch([event]), .persisted)
        let encoded = try String(contentsOf: url, encoding: .utf8)
        let localizedCopy = event.presentation(localization: loc)
        XCTAssertTrue(encoded.contains(sessionID.description))
        XCTAssertTrue(encoded.contains("voiceRecovery"))
        XCTAssertFalse(encoded.contains(localizedCopy.title))
        XCTAssertFalse(encoded.contains(localizedCopy.details))

        let reloaded = try XCTUnwrap(ActivityHistoryStore(fileURL: url).recentEvents().first)
        XCTAssertEqual(reloaded.referenceID, sessionID.description)
        XCTAssertEqual(reloaded.action, .reviewRecoveredVoice)
        XCTAssertEqual(reloaded.timestamp, recordedAt)

        loc.language = .en
        let english = reloaded.presentation(localization: loc)
        loc.language = .ko
        let korean = reloaded.presentation(localization: loc)
        XCTAssertNotEqual(english.title, korean.title)
        XCTAssertNotEqual(english.details, korean.details)
        XCTAssertTrue(english.details.contains("37"))
        XCTAssertTrue(korean.details.contains("37"))
    }

    func testRepeatedStateReplacesInsteadOfFloodingTheRing() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = ActivityHistoryStore(fileURL: temp.appendingPathComponent("activity.json"))

        for _ in 0..<100 {
            XCTAssertEqual(store.record(.injectionFailed, localization: loc), .persisted)
        }

        XCTAssertEqual(store.recentEvents().count, 1)
        XCTAssertEqual(store.recentEvents().first?.category, .expansion)
    }

    func testAIDiagnosticsPublishesOnlyTheTypedFailureSignal() {
        var published: [ActivitySignal] = []
        let diagnostics = AIDiagnosticsStore(activitySink: { published.append($0) })

        diagnostics.recordFailure(
            kind: "proofread",
            error: "frameworkError",
            detail: "never persist this free-form framework detail"
        )

        XCTAssertEqual(published, [.aiFailed])
    }
}
