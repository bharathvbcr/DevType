import Foundation
import Yams

/// Admission for YAML that DevType has not imported yet.
///
/// `Yams.load` is the wrong front door for a pack nobody here wrote. It hands the document
/// straight to `Constructor`, which does two things a hostile file can steer:
///
/// - It rebuilds the referenced subtree at *every* alias occurrence, so nested aliases expand
///   multiplicatively. The byte budgets upstream bound the file, not what the file expands
///   into, and a few hundred bytes can ask for more memory than the machine has.
/// - It force-unwraps every mapping key as a `String` (`Constructor.swift:435` in the pinned
///   5.4.0). A legal complex key — `? [a, b]` — traps, and no `do`/`catch` around `Yams.load`
///   catches a force unwrap: the process is simply gone, mid-import, before the preview the
///   user was going to decide from.
///
/// `compose` stops one step earlier and returns the node tree, where an alias *shares* storage
/// with its anchor instead of being copied. So walk that tree under an explicit budget and
/// convert it here, refusing the shapes Espanso does not have rather than trapping on them.
/// Scalars are still Yams' own job — `String.construct(from:)` on a scalar always succeeds,
/// and this is the same `Constructor` `load` would have used, so `true`, `42` and `~` keep the
/// types the importer already reads them as.
enum BoundedYAML {

    /// Total nodes admitted across one document, counting an alias occurrence each time it
    /// appears rather than once per anchor — expansion is the thing being bounded. Espanso's
    /// own published packages run to a few hundred nodes.
    static let maximumNodes = 200_000

    /// Nesting depth. An Espanso match is three or four levels deep; anything approaching this
    /// is a shape no config file has.
    static let maximumDepth = 64

    enum Failure: LocalizedError, Equatable {
        /// A mapping key that is not a scalar. This is the one that used to trap.
        case unsupportedKey
        /// An alias `compose` left unresolved. Guessing at it is worse than refusing it.
        case unresolvedAlias
        case tooManyNodes
        case tooDeep

        var errorDescription: String? {
            switch self {
            case .unsupportedKey:
                return "Unsupported YAML mapping key: keys must be plain text"
            case .unresolvedAlias:
                return "Unresolved YAML alias"
            case .tooManyNodes:
                return "YAML document expands past \(BoundedYAML.maximumNodes) nodes"
            case .tooDeep:
                return "YAML document nests deeper than \(BoundedYAML.maximumDepth) levels"
            }
        }
    }

    /// The document's root mapping, or `[:]` for any other root — matching what the generic
    /// path returned for a root that was not a dictionary.
    static func loadDictionary(data: Data) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        guard let root = try Yams.compose(yaml: text) else { return [:] }
        var budget = Budget()
        guard case .mapping(let mapping) = root else { return [:] }
        return try dictionary(mapping, depth: 0, budget: &budget)
    }

    // MARK: - Walk

    private static func value(_ node: Node, depth: Int, budget: inout Budget) throws -> Any {
        try budget.admit()
        guard depth <= maximumDepth else { throw Failure.tooDeep }

        switch node {
        case .scalar:
            return Constructor.default.any(from: node)

        case .sequence(let sequence):
            var out: [Any] = []
            // Reserve against the sequence's own length, never a count the file asserts.
            out.reserveCapacity(min(sequence.count, 1_024))
            for element in sequence {
                out.append(try value(element, depth: depth + 1, budget: &budget))
            }
            return out

        case .mapping(let mapping):
            return try dictionary(mapping, depth: depth, budget: &budget)

        case .alias:
            throw Failure.unresolvedAlias
        }
    }

    private static func dictionary(
        _ mapping: Node.Mapping,
        depth: Int,
        budget: inout Budget
    ) throws -> [String: Any] {
        guard depth <= maximumDepth else { throw Failure.tooDeep }

        var written: [String: Any] = [:]
        var merged: [String: Any] = [:]

        for (key, value) in mapping {
            try budget.admit()

            // `Tag.name` is internal to Yams; `rawValue` is the same value through the public
            // surface, and matching on it keeps merge detection identical to Yams' own `flatten()`.
            if key.tag.rawValue == Tag.Name.merge.rawValue {
                // `<<: *anchor`. Expanded here under the same budget as everything else —
                // a chain of merges is one more way to ask for a tree that does not fit.
                try mergeInto(&merged, from: value, depth: depth + 1, budget: &budget)
                continue
            }

            guard let name = key.scalar?.string else {
                throw Failure.unsupportedKey
            }

            written[name] = try self.value(value, depth: depth + 1, budget: &budget)
        }

        // Keys written in the mapping beat keys a merge brought in, per the merge-key spec.
        return merged.merging(written) { _, written in written }
    }

    private static func mergeInto(
        _ target: inout [String: Any],
        from node: Node,
        depth: Int,
        budget: inout Budget
    ) throws {
        try budget.admit()
        guard depth <= maximumDepth else { throw Failure.tooDeep }

        switch node {
        case .mapping(let mapping):
            // Earlier merge sources win over later ones, which is the order Yams resolved them in.
            target.merge(try dictionary(mapping, depth: depth, budget: &budget)) { existing, _ in
                existing
            }
        case .sequence(let sequence):
            for element in sequence {
                try mergeInto(&target, from: element, depth: depth + 1, budget: &budget)
            }
        default:
            // A merge value that is neither mapping nor sequence is ignored, as it was before.
            break
        }
    }

    /// One counter for the whole document. Passed `inout` rather than held in a type so there is
    /// no way to walk a subtree with a fresh budget by accident.
    private struct Budget {
        private var remaining = BoundedYAML.maximumNodes

        mutating func admit() throws {
            guard remaining > 0 else { throw Failure.tooManyNodes }
            remaining -= 1
        }
    }
}
