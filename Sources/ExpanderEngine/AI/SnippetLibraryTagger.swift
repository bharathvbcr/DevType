import Foundation
import os

/// Runs `SnippetTagSuggester` over a whole library.
///
/// The suggester was built for one snippet in the editor, where the model has a body the user
/// just typed. An import is the opposite case and the more valuable one: a library arrives all
/// at once, and unless the source file carried `search_terms` every snippet in it is untagged —
/// which now means unfindable by tag and invisible to the Tagged filter.
///
/// Everything the model returns still goes through `normalizedTags`; this type adds no new
/// trust in it. What it adds is the batch discipline: eligibility, a hard cap, cancellation,
/// and a summary that says what it skipped rather than reporting partial work as complete.
public enum SnippetLibraryTagger {

    /// The model call costs real time — roughly a second each on warm assets. Past this many
    /// snippets the run stops and says so; a 2,000-entry import must not silently become a
    /// half-hour of model time.
    public static let maximumBatchSize = 200

    public struct Summary: Equatable, Sendable {
        /// Snippets that came back with at least one usable tag.
        public var tagged: Int = 0
        /// Eligible, asked about, nothing usable returned.
        public var noSuggestion: Int = 0
        /// Not eligible: already tagged, a secret, or too short to carry a topic.
        public var skipped: Int = 0
        /// Eligible but beyond `maximumBatchSize`, or left when the run was cancelled.
        /// Non-zero means this run did **not** cover the library.
        public var notAttempted: Int = 0

        public var isComplete: Bool { notAttempted == 0 }

        public init(tagged: Int = 0, noSuggestion: Int = 0, skipped: Int = 0, notAttempted: Int = 0) {
            self.tagged = tagged
            self.noSuggestion = noSuggestion
            self.skipped = skipped
            self.notAttempted = notAttempted
        }
    }

    /// Whether a snippet is worth spending a model call on.
    ///
    /// Already-tagged snippets are left alone rather than topped up: an Espanso import can carry
    /// `search_terms` the author chose deliberately, and appending to those would bury them.
    public static func isEligible(_ snippet: SnippetModel) -> Bool {
        snippet.tags.isEmpty
            && SnippetTagSuggester.shouldSuggest(body: snippet.replacementText, isSecret: snippet.isSecret)
    }

    /// Tags every eligible snippet in `groups`, returning the updated library and a summary.
    ///
    /// Sequential on purpose: `SnippetTagSuggester` holds a single-flight latch, so concurrent
    /// calls would be dropped rather than parallelised — a fan-out here would report most of the
    /// library as "no suggestion" while doing almost no work.
    ///
    /// Honours cancellation between snippets. A cancelled run returns what it finished, with the
    /// remainder counted in `notAttempted`.
    public static func tagLibrary(
        _ groups: [SnippetGroup],
        engine: SnippetTagSuggester.TaggingEngine?,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> (groups: [SnippetGroup], summary: Summary) {
        var summary = Summary()
        var updated = groups

        let groupNames = groups.map(\.name)
        var targets: [(group: Int, snippet: Int)] = []
        for (gi, group) in groups.enumerated() {
            for (si, snippet) in group.snippets.enumerated() {
                if isEligible(snippet) {
                    targets.append((gi, si))
                } else {
                    summary.skipped += 1
                }
            }
        }

        if targets.count > maximumBatchSize {
            summary.notAttempted += targets.count - maximumBatchSize
            DevTypeLog.store.notice(
                "[AI] library tagging capped at \(maximumBatchSize, privacy: .public); \(summary.notAttempted, privacy: .public) eligible snippets not attempted"
            )
            targets = Array(targets.prefix(maximumBatchSize))
        }

        let total = targets.count
        for (index, target) in targets.enumerated() {
            if Task.isCancelled {
                summary.notAttempted += total - index
                DevTypeLog.store.notice(
                    "[AI] library tagging cancelled after \(index, privacy: .public) of \(total, privacy: .public)"
                )
                break
            }
            progress?(index, total)

            let snippet = updated[target.group].snippets[target.snippet]
            let suggestion = await SnippetTagSuggester.suggest(
                title: snippet.title,
                body: snippet.replacementText,
                isSecret: snippet.isSecret,
                existingTags: snippet.tags,
                groupNames: groupNames,
                engine: engine
            )
            if suggestion.tags.isEmpty {
                summary.noSuggestion += 1
            } else {
                updated[target.group].snippets[target.snippet].tags = suggestion.tags
                summary.tagged += 1
            }
        }

        // The group half of a suggestion is deliberately ignored here. Moving snippets between
        // groups during a batch is not a tagging decision, and an import has just placed them
        // where the source file said they go.
        return (updated, summary)
    }
}
