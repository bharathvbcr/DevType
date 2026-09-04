import XCTest
@testable import ExpanderEngine

/// §7.1 / §6.2 — key-set and format-specifier parity across the en / ko / ja string tables.
///
/// `LocalizationManager.s(_:_:)` ends in `String(format:arguments:)`. A key whose English form
/// says `%d %d %@` and whose Korean form says `%@ %d %d` does not produce a wrong string — it
/// hands an `Int` to `%@`, which reads it as an object pointer. That is a crash, in the
/// user's language, that no English-speaking developer will ever see.
///
/// This test is the reason `LocalizationManager` moved from `Sources/DevTypeApp` (an
/// `executableTarget`, not importable from tests) into `ExpanderEngine`.
final class LocalizationParityTests: XCTestCase {

    private lazy var en = LocalizationManager.stringTable(for: .en)
    private lazy var ko = LocalizationManager.stringTable(for: .ko)
    private lazy var ja = LocalizationManager.stringTable(for: .ja)

    /// Setting `LocalizationManager.language` persists to `UserDefaults.standard`; restore it so
    /// the tests leave no trace.
    private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        super.tearDown()
    }

    private var concrete: [(AppLanguage, [String: String])] {
        [(.en, en), (.ko, ko), (.ja, ja)]
    }

    // MARK: - Sanity

    func testEveryConcreteLanguageHasATable() {
        for (language, table) in concrete {
            XCTAssertFalse(table.isEmpty, "\(language.rawValue) has no strings at all")
        }
        XCTAssertTrue(LocalizationManager.stringTable(for: .system).isEmpty)
    }

    func testConcreteCasesExcludeSystem() {
        XCTAssertEqual(AppLanguage.concreteCases, [.en, .ko, .ja])
        XCTAssertEqual(AppLanguage.bundleLocalizationCodes, ["en", "ko", "ja"])
    }

    // MARK: - Key parity

    /// `ko` and `ja` have no grammatical plural, so `pluralCategory` always picks `.other` for
    /// them and a `.one` variant would be dead weight. Every *other* key must exist everywhere.
    func testKoreanAndJapaneseCoverEveryNonPluralEnglishKey() {
        for (language, table) in [(AppLanguage.ko, ko), (AppLanguage.ja, ja)] {
            let missing = Set(en.keys)
                .subtracting(table.keys)
                .filter { !$0.hasSuffix(".one") }
                .sorted()
            XCTAssertTrue(
                missing.isEmpty,
                "\(language.rawValue) is missing \(missing.count) key(s): \(missing)"
            )
        }
    }

    func testNoLanguageHasKeysEnglishDoesNotHave() {
        for (language, table) in [(AppLanguage.ko, ko), (AppLanguage.ja, ja)] {
            let extra = Set(table.keys).subtracting(en.keys).sorted()
            XCTAssertTrue(
                extra.isEmpty,
                "\(language.rawValue) has \(extra.count) key(s) with no English fallback: \(extra)"
            )
        }
    }

    func testKoreanAndJapaneseHaveIdenticalKeySets() {
        let onlyKo = Set(ko.keys).subtracting(ja.keys).sorted()
        let onlyJa = Set(ja.keys).subtracting(ko.keys).sorted()
        XCTAssertTrue(onlyKo.isEmpty, "ko-only keys: \(onlyKo)")
        XCTAssertTrue(onlyJa.isEmpty, "ja-only keys: \(onlyJa)")
    }

    /// Every `.one` variant needs a matching `.other` in **every** language, because
    /// `lookupPlural` falls back `key.<category>` → `key.other` → `key`.
    func testEveryPluralOneVariantHasAnOtherVariantEverywhere() {
        let oneKeys = en.keys.filter { $0.hasSuffix(".one") }
        XCTAssertFalse(oneKeys.isEmpty, "Expected at least one pluralized key to guard")
        for key in oneKeys {
            let base = String(key.dropLast(".one".count))
            for (language, table) in concrete {
                XCTAssertNotNil(
                    table["\(base).other"],
                    "\(language.rawValue) is missing \(base).other"
                )
            }
            // `p(_:count:_:)` passes the same arguments whichever variant is selected, so the
            // two variants must agree on argument types too.
            XCTAssertEqual(
                Self.formatSignature(en[key] ?? ""),
                Self.formatSignature(en["\(base).other"] ?? ""),
                "en \(base): .one and .other take different arguments"
            )
        }
    }

    func testNoEmptyValues() {
        for (language, table) in concrete {
            let blanks = table.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .keys.sorted()
            XCTAssertTrue(blanks.isEmpty, "\(language.rawValue) has blank values for \(blanks)")
        }
    }

    // MARK: - Format specifier parity (the crash-prevention half)

    func testFormatSpecifiersMatchAcrossLanguages() {
        var failures: [String] = []
        for key in en.keys.sorted() {
            let reference = Self.formatSignature(en[key] ?? "")
            for (language, table) in [(AppLanguage.ko, ko), (AppLanguage.ja, ja)] {
                guard let translated = table[key] else { continue }
                let candidate = Self.formatSignature(translated)
                if candidate != reference {
                    failures.append(
                        "\(key): en=\(Self.describe(reference)) \(language.rawValue)=\(Self.describe(candidate))"
                    )
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "String(format:) argument mismatch — these crash at runtime:\n" + failures.joined(separator: "\n")
        )
    }

    /// The AI preview passes signed `Int` deltas to these keys. `%@` asks CFString to interpret
    /// that integer as an Objective-C object pointer, which caused the EXC_BAD_ACCESS seen in
    /// the v0.1.1 crash reports. Keep the contract explicit and exercise the real formatter.
    func testAIPreviewDeltaFormatsAcceptIntegerArguments() {
        let deltaKeys = [
            ("ai.preview.delta.words", 3),
            ("ai.preview.delta.chars", -2)
        ]
        let expectedSignature = [1: Character("d")]

        for (language, table) in concrete {
            for (key, value) in deltaKeys {
                let format = table[key] ?? ""
                let signature = Self.formatSignature(format)
                XCTAssertEqual(
                    signature,
                    expectedSignature,
                    "\(language.rawValue) \(key) must format an Int with %d, not an object placeholder."
                )
                guard signature == expectedSignature else { continue }

                let manager = LocalizationManager()
                manager.language = language
                let rendered = manager.s(key, value)
                XCTAssertTrue(rendered.contains(String(value)), "\(language.rawValue) \(key) lost its delta")
            }
        }
    }

    /// Mixing `%1$d` with a bare `%d` in one format string is undefined behaviour in CFString.
    func testAStringIsEitherFullyPositionalOrFullySequential() {
        for (language, table) in concrete {
            for (key, value) in table {
                let specifiers = Self.specifiers(in: value)
                guard !specifiers.isEmpty else { continue }
                let positional = specifiers.filter { $0.position != nil }.count
                XCTAssertTrue(
                    positional == 0 || positional == specifiers.count,
                    "\(language.rawValue) \(key) mixes positional and sequential specifiers: \(value)"
                )
            }
        }
    }

    // MARK: - Voice HUD Keys

    func testVoiceHUDKeysResolveNonEmptyInAllLanguages() {
        let expectedVoiceKeys = [
            "voice.hud.title",
            "voice.hud.title.model",
            "voice.hud.prompt",
            "voice.hud.placeholder",
            "voice.hud.listening",
            "voice.hud.status.listening",
            "voice.hud.listeningEllipsis",
            "voice.hud.live",
            "voice.hud.status.live",
            "voice.hud.polishing",
            "voice.hud.status.polishing",
            "voice.hud.inserted",
            "voice.hud.status.inserted",
            "voice.hud.failed",
            "voice.hud.status.failed",
            "voice.hud.ax",
            "voice.hud.ax.title",
            "voice.error.noMicrophone",
            "voice.error.microphoneDenied",
            "voice.error.speechRecognitionDenied",
            "voice.error.accessibilityDenied",
            "voice.error.noSpeech",
            "voice.error.audioInterrupted",
            "voice.error.diskFull",
            "voice.error.audioEncoding",
            "voice.error.invalidAPIKey",
            "voice.error.endpointUnreachable",
            "voice.error.modelUnavailable",
            "voice.error.modelIntegrity",
            "voice.error.rateLimited",
            "voice.error.quotaExhausted",
            "voice.error.timeout",
            "voice.error.transcriptValidation",
            "voice.error.correctionRejected",
            "voice.error.targetChanged",
            "voice.error.secureInput",
            "voice.error.sessionSave",
            "voice.error.superseded",
            "voice.result.copiedCharacters",
            "voice.ai.empty.lastInsertion",
            "voice.ai.empty.selection",
            "voice.ai.empty.spoken",
            "voice.ai.working",
            "voice.ai.emptyOutput",
            "voice.ai.failed"
        ]

        for (language, table) in concrete {
            for key in expectedVoiceKeys {
                guard let value = table[key] else {
                    XCTFail("\(language.rawValue) missing voice HUD key: \(key)")
                    continue
                }
                XCTAssertFalse(value.isEmpty, "\(language.rawValue) has empty value for \(key)")
                XCTAssertNotEqual(value, key, "\(language.rawValue) key \(key) must not resolve to the key name itself")
            }
        }
    }

    func testActivityRecoveryAndCopyFailureKeysResolveInAllLanguages() {
        let expectedKeys = [
            "activity.clear.failed.title",
            "activity.clear.failed.message",
            "diagnostics.copy.failed.title",
            "diagnostics.copy.failed.message",
            "diagnostics.copy.filtered",
            "prefs.voice.tracing.delete",
            "prefs.voice.tracing.status.off",
            "prefs.voice.tracing.status.on",
            "prefs.voice.tracing.status.deleted",
            "prefs.voice.tracing.status.deletedCapturing",
            "prefs.voice.tracing.status.deleteFailed",
            "prefs.voice.tracing.status.startFailed",
            "prefs.voice.tracing.status.readFailed",
            "prefs.voice.tracing.status.incomplete",
            "prefs.voice.tracing.status.empty",
            "prefs.voice.tracing.deleteFailed.title",
            "prefs.voice.tracing.deleteFailed.message",
            "prefs.voice.tracing.disableDeleteFailed.title",
            "prefs.voice.tracing.disableDeleteFailed.message",
            "prefs.voice.tracing.startFailed.title",
            "prefs.voice.tracing.startFailed.message",
            "prefs.voice.tracing.readFailed.title",
            "prefs.voice.tracing.readFailed.message",
            "prefs.voice.tracing.incomplete.title",
            "prefs.voice.tracing.incomplete.message",
            "activity.action.permissions",
            "activity.action.manager",
            "activity.action.settings",
            "activity.action.testLab",
            "activity.action.copyInfo",
            "activity.action.review",
            "activity.action.aiSettings",
            "activity.action.voiceSettings",
            "activity.action.hotkeySettings",
            "activity.permission.required.title",
            "activity.permission.tapFailed.title",
            "activity.permission.tapFailed.details",
            "activity.permission.degraded.title",
            "activity.permission.degraded.details",
            "activity.permission.ready.title",
            "activity.permission.ready.details",
            "activity.expansion.refused.title",
            "activity.expansion.refused.details",
            "activity.expansion.failed.title",
            "activity.expansion.failed.details",
            "activity.secureInput.active.title",
            "activity.secureInput.active.details",
            "activity.secureInput.released.title",
            "activity.secureInput.released.details",
            "activity.library.readBlocked.title",
            "activity.library.readBlocked.details",
            "activity.library.corrupted.title",
            "activity.library.corrupted.details",
            "activity.library.emptyFile.title",
            "activity.library.emptyFile.details",
            "activity.library.saveFailed.title",
            "activity.library.saveFailed.details",
            "activity.library.conflicts.title",
            "activity.library.conflicts.details",
            "activity.library.restored.title",
            "activity.library.restored.details",
            "activity.import.completed.title",
            "activity.import.notSaved.title",
            "activity.import.completed.details",
            "activity.import.failed.title",
            "activity.import.failed.details",
            "activity.ai.failed.title",
            "activity.ai.failed.details",
            "activity.voice.failed.title",
            "activity.voice.failed.details",
            "activity.hotkey.failed.title",
            "activity.hotkey.failed.details",
            "activity.recovery.activityTitle",
            "activity.recovery.activityDetails",
            "activity.recovery.title",
            "activity.recovery.subtitle",
            "activity.recovery.guidance",
            "activity.recovery.transcript",
            "activity.recovery.copied",
            "activity.recovery.copyFailed.title",
            "activity.recovery.copyFailed.message",
            "activity.recovery.delete.title",
            "activity.recovery.delete.message",
            "activity.recovery.deleteFailed.title",
            "activity.recovery.deleteFailed.message"
        ]

        for (language, table) in concrete {
            for key in expectedKeys {
                let value = table[key]
                XCTAssertNotNil(value, "\(language.rawValue) missing activity/recovery key: \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language.rawValue) has empty activity/recovery key: \(key)")
            }
        }
    }

    func testImportExportProgressAndFailureKeysResolveInAllLanguages() {
        let expectedKeys = [
            "alert.import.progress.parsing.title",
            "alert.import.progress.parsing.message",
            "alert.import.progress.committing.title",
            "alert.import.progress.committing.message",
            "alert.import.failed.unavailable",
            "alert.import.failed.unsupported",
            "alert.import.failed.empty",
            "alert.import.failed.malformed",
            "alert.import.failed.access",
            "alert.import.failed.limit.files",
            "alert.import.failed.limit.bytes",
            "alert.import.failed.limit.snippets",
            "alert.import.failed.generic",
            "alert.import.note.richText.other",
            "alert.import.note.script.other",
            "alert.import.note.missingAbbreviation.other",
            "alert.import.note.disabledGroup.other",
            "alert.import.note.wordBoundary.other",
            "alert.import.note.oversized.other",
            "alert.import.note.imageImported.other",
            "alert.import.note.imageSkipped.other",
            "alert.import.note.markdown.other",
            "alert.import.note.appScope.other",
            "alert.import.note.propagateCase.other",
            "alert.import.note.unsupported.other",
            "alert.import.saveFailed.title",
            "alert.import.saveFailed.remote",
            "alert.import.saveFailed.schema",
            "alert.import.saveFailed.generic",
            "export.inprogress.title",
            "export.inprogress.message",
            "export.progress.title",
            "export.progress.message",
            "export.failed.access",
            "export.failed.space",
            "export.failed.encoding",
            "export.failed.generic"
        ]

        for (language, table) in concrete {
            for key in expectedKeys {
                let value = table[key]
                XCTAssertNotNil(value, "\(language.rawValue) missing import/export key: \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language.rawValue) has empty import/export key: \(key)")
            }
        }
    }

    /// These keys are consumed by the executable target, so a missing entry does not fail
    /// compilation; `LocalizationManager` would quietly display the key itself instead.
    /// Keep the high-traffic cross-screen vocabulary covered at the engine boundary.
    func testExecutableUIKeysDoNotFallBackToRawKeyNames() {
        let keys = [
            "menu.muteFrontmost",
            "manager.snippet.new",
            "manager.context.duplicate",
            "manager.context.delete",
            "manager.disable",
            "manager.enable",
            "common.copy",
            "common.delete",
            "common.edit",
            "ai.preview.action.replace",
            "editor.macroGuide",
            "import.preview.mode",
            "library.health.conflictsNone",
            "snippets.filter.empty",
            "lab.secure.inactive",
            "lab.status.editable",
            "lab.status.selected"
        ]

        for (language, table) in concrete {
            for key in keys {
                XCTAssertNotEqual(
                    table[key],
                    key,
                    "\(language.rawValue) \(key) must have a localized value"
                )
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }
    }

    func testPermissionCopyGuidanceResolvesInEveryLanguage() {
        let snapshot = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: false)
        for language in AppLanguage.concreteCases {
            let manager = LocalizationManager()
            manager.language = language
            let copy = PermissionCopy.localized(using: manager)
            let values = [
                copy.unlockDescription(for: .inputMonitoring),
                copy.openSettingsWithoutRequestHint(
                    for: .accessibility,
                    bundleID: PermissionCopy.expectedBundleIdentifier
                ),
                copy.notListedInSettingsGuidance(
                    for: .inputMonitoring,
                    bundleID: PermissionCopy.expectedBundleIdentifier,
                    appPath: "/Applications/DevType.app",
                    siblingPaths: [],
                    binaryPath: "/Applications/DevType.app/Contents/MacOS/DevType"
                ),
                copy.settingsOpenFailureMessage(for: .postEvent),
                copy.livePreflightSummary(snapshot: snapshot),
                copy.missingCapabilitiesSummary(snapshot)
            ]

            for value in values {
                XCTAssertFalse(
                    value.contains("permission."),
                    "\(language.rawValue) exposed a raw permission localization key: \(value)"
                )
            }
            XCTAssertTrue(
                values[2].contains("/Applications/DevType.app"),
                "\(language.rawValue) dropped the diagnostic app path"
            )
        }
    }

    // MARK: - Lookup behaviour

    func testUnknownKeyFallsBackToTheKeyItself() {
        let manager = LocalizationManager()
        XCTAssertEqual(manager.s("devtype.no.such.key"), "devtype.no.such.key")
    }

    func testEnglishPluralSelectsOneAndOther() {
        let manager = LocalizationManager()
        manager.language = .en
        XCTAssertEqual(manager.p("stats.uses", count: 1, 1), "1 use")
        XCTAssertEqual(manager.p("stats.uses", count: 3, 3), "3 uses")
        XCTAssertEqual(manager.p("stats.uses", count: 0, 0), "0 uses")
    }

    func testKoreanFallsBackToTheOtherVariant() {
        let manager = LocalizationManager()
        manager.language = .ko
        // Korean has no `.one`; both counts must resolve to the single Korean form.
        let one = manager.p("stats.uses", count: 1, 1)
        let many = manager.p("stats.uses", count: 5, 5)
        XCTAssertFalse(one.contains("stats.uses"), "Plural lookup fell through to the raw key")
        XCTAssertTrue(one.hasPrefix("1"))
        XCTAssertTrue(many.hasPrefix("5"))
    }

    func testLanguageResolutionIsTableDriven() {
        let manager = LocalizationManager()
        for language in AppLanguage.concreteCases {
            manager.language = language
            XCTAssertEqual(manager.effectiveLanguageCode(), language.rawValue)
        }
    }

    // MARK: - Signature helpers

    private struct Specifier: Equatable {
        let position: Int?
        let conversion: Character
    }

    /// Parses `%[position$][flags][width][.precision][length]conversion`, skipping `%%`.
    private static func specifiers(in format: String) -> [Specifier] {
        var result: [Specifier] = []
        let characters = Array(format)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else {
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { break }
            if characters[index] == "%" {  // literal percent
                index += 1
                continue
            }

            // Optional `N$` positional prefix.
            var position: Int?
            var digits = ""
            var probe = index
            while probe < characters.count, characters[probe].isNumber {
                digits.append(characters[probe])
                probe += 1
            }
            if !digits.isEmpty, probe < characters.count, characters[probe] == "$" {
                position = Int(digits)
                index = probe + 1
            }

            // Flags, width, precision, length modifiers — all irrelevant to argument type.
            while index < characters.count,
                  "-+ #0123456789.*hlLqzjt".contains(characters[index]) {
                index += 1
            }
            guard index < characters.count else { break }
            result.append(Specifier(position: position, conversion: characters[index]))
            index += 1
        }
        return result
    }

    /// Ordered conversion characters, indexed by argument position. Positional and sequential
    /// forms both reduce to "argument N is of type X", which is exactly what must match.
    private static func formatSignature(_ format: String) -> [Int: Character] {
        var signature: [Int: Character] = [:]
        var sequential = 0
        for specifier in specifiers(in: format) {
            let position: Int
            if let explicit = specifier.position {
                position = explicit
            } else {
                sequential += 1
                position = sequential
            }
            signature[position] = specifier.conversion
        }
        return signature
    }

    private static func describe(_ signature: [Int: Character]) -> String {
        signature.keys.sorted().map { "\($0):%\(signature[$0]!)" }.joined(separator: ",")
    }
}
