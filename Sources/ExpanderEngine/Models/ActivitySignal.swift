import Foundation

/// Typed, privacy-bounded events that may enter the persistent Recent Activity list.
/// Associated values are enums, booleans, counters, or OSStatus values; free-form user text and
/// raw error descriptions are deliberately impossible to pass through this API.
public enum ActivitySignal: Codable, Equatable, Sendable {
    public enum LibraryIssue: String, Codable, Equatable, Sendable {
        case readBlocked
        case corrupted
        case emptyFile
        case saveFailed
        case conflicts
    }

    case permissionState(snapshot: PermissionSnapshot, tapRunning: Bool)
    case injectionRefused
    case injectionFailed
    case secureInputChanged(active: Bool)
    case libraryIssue(LibraryIssue, affectedCount: Int?)
    case libraryRestored
    case importCompleted(added: Int, updated: Int, unchanged: Int, saved: Bool)
    case importFailed
    case aiFailed
    case voiceTerminal(VoiceTerminalDiagnostic)
    case voiceRecovery(sessionID: VoiceSessionID, characterCount: Int, recordedAt: Date)
    case hotkeyRegistrationFailed(status: Int32)

    struct Descriptor: Equatable {
        let category: ActivityHistoryStore.EventCategory
        let title: String
        let details: String
        let action: ActivityHistoryStore.EventAction
        let deduplicationKey: String
        let referenceID: String?

        init(
            category: ActivityHistoryStore.EventCategory,
            title: String,
            details: String,
            action: ActivityHistoryStore.EventAction,
            deduplicationKey: String,
            referenceID: String? = nil
        ) {
            self.category = category
            self.title = title
            self.details = details
            self.action = action
            self.deduplicationKey = deduplicationKey
            self.referenceID = referenceID
        }
    }

    func descriptor(localization loc: LocalizationManager = .shared) -> Descriptor {
        switch self {
        case .permissionState(let snapshot, let tapRunning):
            let mask = (snapshot.canUseAX ? 4 : 0)
                | (snapshot.canListenTap ? 2 : 0)
                | (snapshot.canPostEvents ? 1 : 0)
            let title: String
            let details: String
            if snapshot.blocksDefaultEventTap {
                title = loc.s("activity.permission.required.title")
                details = PermissionCopy.localized(using: loc).missingCapabilitiesSummary(snapshot)
            } else if !tapRunning {
                title = loc.s("activity.permission.tapFailed.title")
                details = loc.s("activity.permission.tapFailed.details")
            } else if !snapshot.canPostEvents {
                title = loc.s("activity.permission.degraded.title")
                details = loc.s("activity.permission.degraded.details")
            } else {
                title = loc.s("activity.permission.ready.title")
                details = loc.s("activity.permission.ready.details")
            }
            return Descriptor(
                category: .general,
                title: title,
                details: details,
                action: .openPermissionRecovery,
                deduplicationKey: "permission-state-\(mask)-\(tapRunning ? 1 : 0)"
            )

        case .injectionRefused:
            return Descriptor(
                category: .expansion,
                title: loc.s("activity.expansion.refused.title"),
                details: loc.s("activity.expansion.refused.details"),
                action: .openLab,
                deduplicationKey: "injection-refused"
            )

        case .injectionFailed:
            return Descriptor(
                category: .expansion,
                title: loc.s("activity.expansion.failed.title"),
                details: loc.s("activity.expansion.failed.details"),
                action: .copyDiagnostics,
                deduplicationKey: "injection-failed"
            )

        case .secureInputChanged(let active):
            return Descriptor(
                category: .secureInput,
                title: loc.s(active
                    ? "activity.secureInput.active.title"
                    : "activity.secureInput.released.title"),
                details: loc.s(active
                    ? "activity.secureInput.active.details"
                    : "activity.secureInput.released.details"),
                action: .none,
                deduplicationKey: active ? "secure-input-active" : "secure-input-released"
            )

        case .libraryIssue(let issue, let affectedCount):
            let count = max(0, affectedCount ?? 0)
            return Descriptor(
                category: .library,
                title: loc.s("activity.library.\(issue.rawValue).title"),
                details: issue == .conflicts
                    ? loc.s("activity.library.conflicts.details", count)
                    : loc.s("activity.library.\(issue.rawValue).details"),
                action: .openSnippetManager,
                deduplicationKey: "library-\(issue.rawValue)"
            )

        case .libraryRestored:
            return Descriptor(
                category: .library,
                title: loc.s("activity.library.restored.title"),
                details: loc.s("activity.library.restored.details"),
                action: .openSnippetManager,
                deduplicationKey: "library-restored"
            )

        case .importCompleted(let added, let updated, let unchanged, let saved):
            return Descriptor(
                category: .importExport,
                title: loc.s(saved
                    ? "activity.import.completed.title"
                    : "activity.import.notSaved.title"),
                details: loc.s(
                    "activity.import.completed.details",
                    max(0, added),
                    max(0, updated),
                    max(0, unchanged)
                ),
                action: .openSnippetManager,
                deduplicationKey: "import-latest-\(saved ? "saved" : "not-saved")"
            )

        case .importFailed:
            return Descriptor(
                category: .importExport,
                title: loc.s("activity.import.failed.title"),
                details: loc.s("activity.import.failed.details"),
                action: .openSnippetManager,
                deduplicationKey: "import-failed"
            )

        case .aiFailed:
            return Descriptor(
                category: .ai,
                title: loc.s("activity.ai.failed.title"),
                details: loc.s("activity.ai.failed.details"),
                action: .openAIPreferences,
                deduplicationKey: "ai-failed"
            )

        case .voiceTerminal(let diagnostic):
            let titleKey: String
            let detailsKey: String
            let action: ActivityHistoryStore.EventAction
            switch diagnostic.outcome {
            case .failed:
                titleKey = "activity.voice.failed.title"
                detailsKey = "activity.voice.failed.details"
                action = .openVoicePreferences
            case .cancelled:
                titleKey = "activity.voice.cancelled.title"
                detailsKey = "activity.voice.cancelled.details"
                action = .none
            case .superseded:
                titleKey = "activity.voice.superseded.title"
                detailsKey = "activity.voice.superseded.details"
                action = .none
            }
            let base = loc.s(detailsKey, diagnostic.stage.rawValue, diagnostic.code.rawValue)
            let typedContext = "stage=\(diagnostic.stage.rawValue) "
                + "code=\(diagnostic.code.rawValue) "
                + "provider=\(diagnostic.provider.rawValue) "
                + "locality=\(diagnostic.locality.rawValue) "
                + "recoverability=\(diagnostic.recoverability.rawValue)"
            return Descriptor(
                category: .voice,
                title: loc.s(titleKey),
                details: "\(base) [\(typedContext)]",
                action: action,
                deduplicationKey: "voice-terminal-\(diagnostic.outcome.rawValue)-"
                    + "\(diagnostic.stage.rawValue)-\(diagnostic.code.rawValue)-"
                    + "\(diagnostic.provider.rawValue)-\(diagnostic.locality.rawValue)"
            )

        case .voiceRecovery(let sessionID, let characterCount, let recordedAt):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: loc.effectiveLanguageCode())
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return Descriptor(
                category: .voice,
                title: loc.s("activity.recovery.activityTitle"),
                details: loc.s(
                    "activity.recovery.activityDetails",
                    max(0, characterCount),
                    formatter.string(from: recordedAt)
                ),
                action: .reviewRecoveredVoice,
                deduplicationKey: "voice-recovery-\(sessionID.description)",
                referenceID: sessionID.description
            )

        case .hotkeyRegistrationFailed(let status):
            return Descriptor(
                category: .hotkey,
                title: loc.s("activity.hotkey.failed.title"),
                details: loc.s("activity.hotkey.failed.details", Int(status)),
                action: .openHotkeyPreferences,
                deduplicationKey: "hotkey-failed-\(status)"
            )
        }
    }
}
