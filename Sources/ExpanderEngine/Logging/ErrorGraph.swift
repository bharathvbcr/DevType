import Foundation

/// Bounded, cycle-safe walk over an error and the errors it wraps.
///
/// Apple frameworks report a failure as a tree. The error a caller catches is usually a
/// wrapper — `FoundationModels.LanguageModelError -1` — whose actual cause sits several levels
/// down under `NSUnderlyingErrorKey` or `NSMultipleUnderlyingErrorsKey`. Reading only the outer
/// error is how "the model service refused to run under memory pressure" reached users as an
/// opaque "SensitiveContentAnalysisML error 15", and reached our logs as `code=-1`.
///
/// `userInfo` is untyped and anyone can populate it, so the walk bridges each element on its
/// own (a mixed array must not lose its errors to one failed cast), skips values that are not
/// errors, never revisits an instance, and stops at fixed depth and node caps. The caps are what
/// guarantee termination: a Swift error that wraps itself is re-boxed on every bridge, so
/// identity tracking alone cannot catch that cycle.
public enum ErrorGraph {
    public struct Node: Equatable, Sendable {
        public let domain: String
        public let code: Int
        /// Hops from the error that was passed in; the root is 0.
        public let depth: Int
    }

    public struct Walk: Equatable, Sendable {
        /// Breadth-first, root first.
        public let nodes: [Node]
        /// A cap stopped the walk while wrapped errors remained unvisited. A lookup that found
        /// nothing in a truncated walk has not shown the error is absent.
        public let truncated: Bool
    }

    public static let defaultMaxDepth = 8
    public static let defaultMaxNodes = 64

    public static func walk(
        _ error: Error,
        maxDepth: Int = defaultMaxDepth,
        maxNodes: Int = defaultMaxNodes
    ) -> Walk {
        let depthCap = max(0, maxDepth)
        let nodeCap = max(1, maxNodes)
        let root = error as NSError
        // Every visited instance stays in `queue` until return, so no `ObjectIdentifier` in
        // `seen` can be reused by a later allocation during the walk.
        var queue: [(error: NSError, depth: Int)] = [(root, 0)]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        var head = 0
        var nodes: [Node] = []
        var truncated = false

        while head < queue.count {
            let (current, depth) = queue[head]
            head += 1
            nodes.append(Node(domain: current.domain, code: current.code, depth: depth))

            // One past the cap: a node with more causes than could ever be visited stops being
            // read there, and that unread remainder makes the walk truncated, never complete.
            let fetchLimit = nodeCap + 1
            let children = underlyingErrors(of: current, limit: fetchLimit)
            if children.count == fetchLimit { truncated = true }
            // A child already seen is a cycle back into the walk, not unvisited work.
            let fresh = children.filter { !seen.contains(ObjectIdentifier($0)) }
            if fresh.isEmpty { continue }
            if depth >= depthCap {
                truncated = true
                continue
            }
            for child in fresh {
                guard queue.count < nodeCap else {
                    truncated = true
                    break
                }
                guard seen.insert(ObjectIdentifier(child)).inserted else { continue }
                queue.append((child, depth + 1))
            }
        }
        return Walk(nodes: nodes, truncated: truncated)
    }

    /// Wrapped errors of one node, at most `limit` of them. Reads both Foundation keys: the
    /// single cause and the multiple-causes array. Either may hold a non-error value or the
    /// wrong shape (a lone error where an array belongs), so each value is checked on its own.
    static func underlyingErrors(of error: NSError, limit: Int) -> [NSError] {
        guard limit > 0 else { return [] }
        let info = error.userInfo
        var result: [NSError] = []
        if let single = info[NSUnderlyingErrorKey] as? Error {
            result.append(single as NSError)
        }
        guard result.count < limit, let multiple = info[NSMultipleUnderlyingErrorsKey] else {
            return result
        }
        if let elements = multiple as? [Any] {
            for element in elements {
                guard result.count < limit else { break }
                if let wrapped = element as? Error {
                    result.append(wrapped as NSError)
                }
            }
        } else if let lone = multiple as? Error {
            result.append(lone as NSError)
        }
        return result
    }
}
