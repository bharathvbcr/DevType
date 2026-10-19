import CryptoKit
import Foundation

extension SnippetStore {
    // MARK: - Trigger hygiene (§1.9)

    /// §1.9: **non-destructive**. This used to silently drop empty-trigger and
    /// duplicate-trigger snippets on every save *and* every load, so duplicating a
    /// snippet and editing the body before the trigger lost the snippet at the next
    /// save. Problems are now reported through `triggerConflicts()` instead.
    public static func sanitize(_ snippets: [SnippetModel]) -> [SnippetModel] {
        snippets
    }

    public static func sanitizeGroups(_ groups: [SnippetGroup]) -> [SnippetGroup] {
        SnippetDocument(groups: groups).transactionGroups
    }

    /// User preference: report trigger conflicts (duplicates, shadowing, empty triggers) in the
    /// editor and library health UI. On by default; the menu bar exposes the switch.
    ///
    /// Only the *reporting* is optional. The matcher's behaviour with colliding triggers is
    /// unchanged either way — turning this off means "stop warning me", not "make `:Hi` and
    /// `:hi` both fire".
    public static let conflictDetectionDisabledDefaultsKey = "devtype.conflictDetection.disabled"

    public static var isConflictDetectionEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: conflictDetectionDisabledDefaultsKey) }
        set { UserDefaults.standard.set(!newValue, forKey: conflictDetectionDisabledDefaultsKey) }
    }

    /// §1.9: triggers the matcher will shadow, plus unusable (empty) triggers.
    ///
    /// Empty when the user has switched conflict detection off — every reporting surface
    /// (editor validation, library health) goes through here or checks the flag itself, so one
    /// switch silences all of them. `triggerConflicts(in:)` stays ungated: it is the pure
    /// detector, and callers that need the truth regardless of preference (tests, internals)
    /// use it directly.
    public func triggerConflicts() -> [TriggerConflict] {
        guard Self.isConflictDetectionEnabled else { return [] }
        return Self.triggerConflicts(in: loadGroups())
    }

    /// Resolves one conflict entry against the latest in-process library snapshot.
    ///
    /// This owns the complete read-modify-write under `rmwLock`. Passing the groups rendered by
    /// the sheet back to `saveGroups` would overwrite edits that landed while the user was
    /// reading or confirming the conflict. The UUID is resolved only after acquiring the lock,
    /// and cache/listener changes still happen only through `saveGroupsSerialized` after a real
    /// disk write.
    public func resolveTriggerConflict(
        snippetID: UUID,
        action: TriggerConflictResolutionAction
    ) -> TriggerConflictResolutionOutcome {
        resolveTriggerConflict(action: action) { groups in
            var matches: [(group: Int, snippet: Int)] = []
            for groupIndex in groups.indices {
                for snippetIndex in groups[groupIndex].snippets.indices
                where groups[groupIndex].snippets[snippetIndex].id == snippetID {
                    matches.append((groupIndex, snippetIndex))
                }
            }
            // UUID-only callers remain idempotent for a well-formed library, but must fail closed
            // when malformed input makes that UUID name more than one physical entry.
            return matches.count == 1 ? matches[0] : nil
        }
    }

    /// Resolves the exact occurrence rendered by the conflict sheet. Unlike the compatibility
    /// UUID-only entry point, this can safely address non-identical duplicate UUIDs. Any moved,
    /// reordered, edited, or indistinguishable duplicate is a stale/ambiguous target and is refused.
    public func resolveTriggerConflict(
        target: TriggerConflictTarget,
        action: TriggerConflictResolutionAction
    ) -> TriggerConflictResolutionOutcome {
        resolveTriggerConflict(action: action) { groups in
            guard target.occurrence >= 0 else { return nil }
            var matches: [(group: Int, snippet: Int)] = []

            for groupIndex in groups.indices where groups[groupIndex].id == target.groupID {
                let sameID = groups[groupIndex].snippets.indices.filter {
                    groups[groupIndex].snippets[$0].id == target.snippetID
                }
                guard sameID.indices.contains(target.occurrence) else { continue }
                let snippetIndex = sameID[target.occurrence]
                let candidate = groups[groupIndex].snippets[snippetIndex]
                guard Self.matchesRenderedConflictTarget(
                    candidate,
                    rendered: target.renderedSnippet,
                    action: action
                ) else { continue }

                // Two byte-for-byte-equivalent duplicate identities cannot be distinguished by a
                // stale UI row even with an ordinal; reject rather than guessing which one moved.
                let indistinguishable = sameID.filter {
                    Self.matchesRenderedConflictTarget(
                        groups[groupIndex].snippets[$0],
                        rendered: target.renderedSnippet,
                        action: action
                    )
                }
                guard indistinguishable.count == 1 else { continue }
                matches.append((groupIndex, snippetIndex))
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func resolveTriggerConflict(
        action: TriggerConflictResolutionAction,
        locate: ([SnippetGroup]) -> (group: Int, snippet: Int)?
    ) -> TriggerConflictResolutionOutcome {
        rmwLock.lock()
        defer { rmwLock.unlock() }

        lock.lock()
        var groups = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        guard let location = locate(groups) else { return .targetUnavailable }

        switch action {
        case .disable:
            // The requested state already holds. Avoid a needless whole-library write while
            // still reporting success: the stale conflict is resolved and a reload will remove it.
            if !groups[location.group].snippets[location.snippet].enabled {
                return .persisted
            }
            groups[location.group].snippets[location.snippet].enabled = false
        case .delete:
            groups[location.group].snippets.remove(at: location.snippet)
        }

        let outcome = saveGroupsSerialized(groups)
        return outcome.didSave ? .persisted : .refused(outcome)
    }

    private static func matchesRenderedConflictTarget(
        _ candidate: SnippetModel,
        rendered: SnippetModel,
        action: TriggerConflictResolutionAction
    ) -> Bool {
        var candidate = candidate
        var rendered = rendered
        if action == .disable {
            // Another surface may already have converged on the requested disabled state. Enabled
            // is therefore the one mutable bit excluded from this action's stale-row fingerprint.
            candidate.enabled = false
            rendered.enabled = false
        }
        return candidate == rendered
    }

    /// §1.9: case folding matches `AbbreviationMatcher` — case-sensitive snippets
    /// key on the exact trigger, case-insensitive ones on `lowercased()` — so the
    /// store and the matcher agree about what collides.
    public static func triggerConflicts(in groups: [SnippetGroup]) -> [TriggerConflict] {
        struct Entry {
            let id: UUID
            let groupName: String
            let trigger: String
            let caseSensitive: Bool
            /// True when `AbbreviationMatcher` fires this trigger the moment it appears at the
            /// buffer suffix, with no terminator. Mirrors match rules (1) and (2): a
            /// punctuation-started trigger fires immediately **regardless** of
            /// `requireWordBoundary`, and any trigger with the flag off fires immediately too.
            /// Only these can shadow a longer trigger.
            let firesWithoutTerminator: Bool
        }

        var empties: [Entry] = []
        var byFolded: [String: [Entry]] = [:]
        var all: [Entry] = []

        for group in groups where group.enabled {
            for snippet in group.snippets {
                // A secret never reaches the matcher (`EventTapEngine.snippets` filters it), so it
                // can neither shadow another trigger nor be shadowed, and an empty trigger on one
                // is intentional rather than a mistake to report. Including them here produced
                // conflicts the user could not act on and warnings about triggers that do nothing.
                // Disabled snippets and snippets in disabled groups are equally absent from the
                // matcher. Reporting either made the resolver's Disable action appear to work
                // while the same duplicate/case/empty warning immediately returned.
                guard snippet.enabled, snippet.isTypedTriggerExpandable else { continue }
                let trigger = snippet.triggerKeyword
                let punctuationStarted = trigger.first.map { !AbbreviationMatcher.isWordCharacter($0) } ?? false
                let entry = Entry(
                    id: snippet.id,
                    groupName: group.name,
                    trigger: trigger,
                    caseSensitive: snippet.isCaseSensitive,
                    firesWithoutTerminator: punctuationStarted || !snippet.requireWordBoundary
                )
                if trigger.isEmpty {
                    empties.append(entry)
                } else {
                    byFolded[trigger.lowercased(), default: []].append(entry)
                    all.append(entry)
                }
            }
        }

        var out: [TriggerConflict] = []
        if !empties.isEmpty {
            out.append(TriggerConflict(
                kind: .emptyTrigger,
                trigger: "",
                snippetIDs: empties.map(\.id),
                groupNames: empties.map(\.groupName)
            ))
        }

        for (folded, entries) in byFolded where entries.count > 1 {
            let sensitive = entries.filter(\.caseSensitive)
            let insensitive = entries.filter { !$0.caseSensitive }

            // Identical spellings among case-sensitive snippets: matcher keeps the first.
            var byExact: [String: [Entry]] = [:]
            for entry in sensitive { byExact[entry.trigger, default: []].append(entry) }
            for (spelling, dupes) in byExact where dupes.count > 1 {
                out.append(TriggerConflict(
                    kind: .duplicateTrigger,
                    trigger: spelling,
                    snippetIDs: dupes.map(\.id),
                    groupNames: dupes.map(\.groupName)
                ))
            }

            // Several case-insensitive snippets fold to one key: matcher keeps the first.
            if insensitive.count > 1 {
                out.append(TriggerConflict(
                    kind: .duplicateTrigger,
                    trigger: folded,
                    snippetIDs: insensitive.map(\.id),
                    groupNames: insensitive.map(\.groupName)
                ))
            }

            // Mixed: the case-sensitive entry wins for its exact spelling, so the
            // case-insensitive snippet is partially shadowed.
            if !insensitive.isEmpty && !sensitive.isEmpty {
                out.append(TriggerConflict(
                    kind: .caseShadow,
                    trigger: folded,
                    snippetIDs: entries.map(\.id),
                    groupNames: entries.map(\.groupName)
                ))
            }
        }

        // Prefix shadowing: a trigger that fires without a terminator makes every longer
        // trigger starting with it unreachable, because the short one fires on the keystroke
        // that completes it — the user never gets to type the rest.
        //
        // This is invisible without the check: both snippets look fine individually, the
        // longer one simply never fires. Note it is asymmetric — only the *shorter* trigger's
        // firing rule matters, since the longer one is never reached.
        // Fold exactly as the matcher keys: case-insensitive triggers compare lowercased.
        // Folded once here rather than inside the scan — the nested loop this replaces folded
        // its candidate on every comparison, so a 1,000-trigger library allocated a million
        // strings to answer a question about prefixes. 180 ms at 2,000 triggers, on the main
        // thread, per keystroke while the Conflicts chip was active. See `TriggerPrefixScan`.
        let foldedKeys = all.map { $0.caseSensitive ? $0.trigger : $0.trigger.lowercased() }
        let scan = TriggerPrefixScan(foldedKeys: foldedKeys)
        for (index, shadower) in all.enumerated() where shadower.firesWithoutTerminator {
            var shadowed: [Entry] = []
            scan.forEachStrictExtension(of: index) { other in
                // A duplicate UUID names the same snippet twice; the old scan skipped those by
                // identity and this must keep doing so.
                guard all[other].id != shadower.id else { return }
                shadowed.append(all[other])
            }
            guard !shadowed.isEmpty else { continue }
            let ordered = shadowed.sorted { $0.trigger < $1.trigger }
            out.append(TriggerConflict(
                kind: .prefixShadow,
                trigger: shadower.trigger,
                snippetIDs: [shadower.id] + ordered.map(\.id),
                groupNames: [shadower.groupName] + ordered.map(\.groupName),
                blockedTriggers: ordered.map(\.trigger)
            ))
        }

        return out.sorted { lhs, rhs in
            if lhs.trigger != rhs.trigger { return lhs.trigger < rhs.trigger }
            let l = lhs.snippetIDs.first?.uuidString ?? ""
            let r = rhs.snippetIDs.first?.uuidString ?? ""
            return l < r
        }
    }
}
