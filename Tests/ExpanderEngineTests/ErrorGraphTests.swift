import Foundation
import XCTest
@testable import ExpanderEngine

/// `ErrorGraph` reads `userInfo` that any framework or caller can fill, so these attack the
/// walk with the shapes that break naive recursion: cycles, self-wrapping Swift errors,
/// unbounded depth and fan-out, junk values, and wrong-shaped keys. The fuzz half checks the
/// walk against an independent reference over seeded random graphs.
final class ErrorGraphTests: XCTestCase {

    // MARK: - Structure

    func testRootOnlyErrorIsOneNode() {
        let walk = ErrorGraph.walk(NSError(domain: "d", code: 7))
        XCTAssertEqual(walk.nodes, [ErrorGraph.Node(domain: "d", code: 7, depth: 0)])
        XCTAssertFalse(walk.truncated)
    }

    func testReadsBothFoundationKeysBreadthFirst() {
        let leaf = NSError(domain: "leaf", code: 3)
        let single = NSError(domain: "single", code: 1, userInfo: [NSUnderlyingErrorKey: leaf])
        let multi = NSError(domain: "multi", code: 2)
        let root = NSError(domain: "root", code: 0, userInfo: [
            NSUnderlyingErrorKey: single,
            NSMultipleUnderlyingErrorsKey: [multi],
        ])

        let walk = ErrorGraph.walk(root)

        XCTAssertEqual(walk.nodes.map(\.domain), ["root", "single", "multi", "leaf"])
        XCTAssertEqual(walk.nodes.map(\.depth), [0, 1, 1, 2])
        XCTAssertFalse(walk.truncated)
    }

    func testMixedArraySkipsJunkAndKeepsEveryError() {
        let root = NSError(domain: "root", code: 0, userInfo: [
            NSMultipleUnderlyingErrorsKey: [
                "not an error", 42, NSNull(), NSError(domain: "a", code: 1),
                ["nested": "dict"], SampleSwiftError.boom, NSError(domain: "b", code: 2),
            ] as [Any],
        ])

        let codes = ErrorGraph.walk(root).nodes.dropFirst().map(\.code)

        XCTAssertEqual(codes.count, 3, "two NSErrors and one bridged Swift error")
        XCTAssertTrue(codes.contains(1))
        XCTAssertTrue(codes.contains(2))
    }

    func testNSArrayFromObjectiveCBridges() {
        let array = NSMutableArray()
        array.add(NSError(domain: "a", code: 1))
        array.add(NSString(string: "junk"))
        let root = NSError(domain: "root", code: 0, userInfo: [NSMultipleUnderlyingErrorsKey: array])

        XCTAssertEqual(ErrorGraph.walk(root).nodes.map(\.domain), ["root", "a"])
    }

    func testLoneErrorUnderTheMultipleKeyIsStillRead() {
        let root = NSError(domain: "root", code: 0, userInfo: [
            NSMultipleUnderlyingErrorsKey: NSError(domain: "lone", code: 9),
        ])
        XCTAssertEqual(ErrorGraph.walk(root).nodes.map(\.domain), ["root", "lone"])
    }

    func testNonErrorValuesUnderEitherKeyAreIgnored() {
        let root = NSError(domain: "root", code: 0, userInfo: [
            NSUnderlyingErrorKey: "a string",
            NSMultipleUnderlyingErrorsKey: "also a string",
        ])
        let walk = ErrorGraph.walk(root)
        XCTAssertEqual(walk.nodes.count, 1)
        XCTAssertFalse(walk.truncated)
    }

    func testSwiftErrorCausesAreBridgedThroughCustomNSError() {
        let inner = NSError(domain: "inner", code: 5)
        let walk = ErrorGraph.walk(WrappingSwiftError(underlying: inner))
        XCTAssertEqual(walk.nodes.last, ErrorGraph.Node(domain: "inner", code: 5, depth: 1))
    }

    // MARK: - Termination

    func testSelfCycleTerminatesWithoutTruncation() {
        let node = GraphError(domain: "self", code: 1)
        node.single = node
        defer { node.single = nil }

        let walk = ErrorGraph.walk(node)

        XCTAssertEqual(walk.nodes.count, 1)
        XCTAssertFalse(walk.truncated, "a cycle back to a visited node is not unvisited work")
    }

    func testMutualCycleVisitsEachInstanceOnce() {
        let a = GraphError(domain: "a", code: 1)
        let b = GraphError(domain: "b", code: 2)
        a.children = [b]
        b.children = [a, b]
        defer { a.children = []; b.children = [] }

        let walk = ErrorGraph.walk(a)

        XCTAssertEqual(walk.nodes.map(\.domain), ["a", "b"])
        XCTAssertFalse(walk.truncated)
    }

    /// A Swift class error that wraps itself is re-boxed on every bridge, so identity cannot
    /// see the cycle. Only the caps stop it — which is why they exist.
    func testSelfWrappingSwiftErrorIsStoppedByTheCaps() {
        let error = SelfWrappingSwiftError()
        let walk = ErrorGraph.walk(error, maxDepth: 8, maxNodes: 64)
        XCTAssertLessThanOrEqual(walk.nodes.count, 64)
        XCTAssertTrue(walk.truncated)
    }

    func testDeepChainStopsAtTheDepthCap() {
        let root = Self.chain(length: 10_000)
        let walk = ErrorGraph.walk(root, maxDepth: 8, maxNodes: 64)
        XCTAssertEqual(walk.nodes.count, 9)
        XCTAssertEqual(walk.nodes.last?.depth, 8)
        XCTAssertTrue(walk.truncated)
    }

    func testChainExactlyAtTheDepthCapIsComplete() {
        let walk = ErrorGraph.walk(Self.chain(length: 9), maxDepth: 8, maxNodes: 64)
        XCTAssertEqual(walk.nodes.count, 9)
        XCTAssertFalse(walk.truncated)
    }

    /// Structural only: a wall-clock bound here would flake under machine load, and reading
    /// past the cap shows up as a node count above it.
    func testHugeFanOutStopsAtTheNodeCap() {
        let children = (0..<200_000).map { NSError(domain: "c", code: $0) }
        let root = NSError(domain: "root", code: -1, userInfo: [NSMultipleUnderlyingErrorsKey: children])

        let walk = ErrorGraph.walk(root, maxDepth: 8, maxNodes: 64)

        XCTAssertEqual(walk.nodes.count, 64)
        XCTAssertTrue(walk.truncated)
        XCTAssertEqual(walk.nodes.last?.code, 62, "children are read in order, up to the cap")
    }

    func testFanOutExactlyAtTheNodeCapIsComplete() {
        let children = (0..<63).map { NSError(domain: "c", code: $0) }
        let root = NSError(domain: "root", code: -1, userInfo: [NSMultipleUnderlyingErrorsKey: children])
        let walk = ErrorGraph.walk(root, maxDepth: 8, maxNodes: 64)
        XCTAssertEqual(walk.nodes.count, 64)
        XCTAssertFalse(walk.truncated)
    }

    func testDegenerateCapsStillReportTheRoot() {
        let root = Self.chain(length: 3)
        for (depth, nodes) in [(0, 64), (-5, 64), (8, 0), (8, -1), (0, 0)] {
            let walk = ErrorGraph.walk(root, maxDepth: depth, maxNodes: nodes)
            XCTAssertEqual(walk.nodes.first?.depth, 0, "depth \(depth) nodes \(nodes)")
            XCTAssertTrue(walk.truncated, "depth \(depth) nodes \(nodes) left wrapped errors unread")
        }
    }

    // MARK: - Fuzz

    /// Seeded random graphs with cycles, shared children, junk values and both keys, checked
    /// against an independent reference walk. Each node has a unique code, so "which errors
    /// did the walk see" is exact.
    func testRandomGraphsMatchTheReferenceWalk() {
        var rng = SplitMix64(seed: 0xDE57_17E0)
        var completeRuns = 0
        for iteration in 0..<2_000 {
            let graph = RandomGraph(rng: &rng)
            defer { graph.breakCycles() }
            let maxDepth = Int.random(in: 0...10, using: &rng)
            let maxNodes = Int.random(in: 1...80, using: &rng)

            let walk = ErrorGraph.walk(graph.root, maxDepth: maxDepth, maxNodes: maxNodes)
            let reference = graph.reachable(maxDepth: maxDepth)

            let context = "iteration \(iteration) nodes \(graph.nodes.count) depth \(maxDepth) cap \(maxNodes)"
            XCTAssertEqual(walk.nodes.first?.code, graph.root.code, context)
            XCTAssertLessThanOrEqual(walk.nodes.count, maxNodes, context)
            XCTAssertEqual(Set(walk.nodes.map(\.code)).count, walk.nodes.count, "revisited: \(context)")
            XCTAssertEqual(walk.nodes.map(\.depth), walk.nodes.map(\.depth).sorted(), "not BFS: \(context)")
            for node in walk.nodes {
                guard let shortest = reference[node.code] else {
                    XCTFail("walk reached \(node.code), which is not reachable: \(context)")
                    continue
                }
                // A capped walk can find a node by a longer path than BFS would; never shorter.
                if walk.truncated {
                    XCTAssertGreaterThanOrEqual(node.depth, shortest, context)
                } else {
                    XCTAssertEqual(node.depth, shortest, "wrong depth for \(node.code): \(context)")
                }
            }
            if walk.truncated {
                XCTAssertTrue(
                    reference.count > walk.nodes.count
                        || graph.hasEdgesBeyond(maxDepth: maxDepth)
                        || graph.hasReachedNode(withMoreErrorCausesThan: maxNodes, maxDepth: maxDepth),
                    "truncated with nothing left to read: \(context)"
                )
            } else {
                completeRuns += 1
                XCTAssertEqual(Set(walk.nodes.map(\.code)), Set(reference.keys), "incomplete walk: \(context)")
            }
        }
        XCTAssertGreaterThan(completeRuns, 200, "the fuzz must exercise complete walks, not only capped ones")
    }

    /// The walk is pure; concurrent callers over one shared graph must agree exactly.
    func testConcurrentWalksOverASharedGraphAgree() {
        var rng = SplitMix64(seed: 42)
        let graph = RandomGraph(rng: &rng, nodeCount: 60)
        defer { graph.breakCycles() }
        let expected = ErrorGraph.walk(graph.root)
        let mismatches = ManagedCounter()

        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            if ErrorGraph.walk(graph.root) != expected { mismatches.increment() }
        }
        XCTAssertEqual(mismatches.value, 0)
    }

    // MARK: - Helpers

    static func chain(length: Int) -> NSError {
        var current = NSError(domain: "chain", code: length - 1)
        for code in stride(from: length - 2, through: 0, by: -1) {
            current = NSError(domain: "chain", code: code, userInfo: [NSUnderlyingErrorKey: current])
        }
        return current
    }
}

// MARK: - Fixtures

/// An `NSError` whose wrapped causes can be rewired after creation — the only way to build a
/// cycle, since a plain `NSError`'s `userInfo` is fixed at init.
final class GraphError: NSError, @unchecked Sendable {
    var single: Any?
    var children: [Any] = []

    override var userInfo: [String: Any] {
        var info: [String: Any] = [:]
        if let single { info[NSUnderlyingErrorKey] = single }
        if !children.isEmpty { info[NSMultipleUnderlyingErrorsKey] = children }
        return info
    }

    init(domain: String, code: Int) {
        super.init(domain: domain, code: code, userInfo: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

enum SampleSwiftError: Error { case boom }

struct WrappingSwiftError: CustomNSError {
    let underlying: NSError
    static var errorDomain: String { "WrappingSwiftError" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying] }
}

final class SelfWrappingSwiftError: CustomNSError {
    static var errorDomain: String { "SelfWrappingSwiftError" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A random directed graph of `GraphError`s, node `i` carrying code `i`. Edges may point
/// anywhere (cycles, self-loops, shared children); junk values are mixed into the arrays.
final class RandomGraph {
    let nodes: [GraphError]
    var root: GraphError { nodes[0] }

    init<R: RandomNumberGenerator>(rng: inout R, nodeCount: Int? = nil) {
        let count = nodeCount ?? Int.random(in: 1...120, using: &rng)
        nodes = (0..<count).map { GraphError(domain: "fuzz", code: $0) }
        for node in nodes {
            if Bool.random(using: &rng), Int.random(in: 0..<4, using: &rng) == 0 {
                node.single = Bool.random(using: &rng)
                    ? nodes[Int.random(in: 0..<count, using: &rng)] as Any
                    : "junk" as Any
            }
            let fanOut = Int.random(in: 0...(Bool.random(using: &rng) ? 3 : 12), using: &rng)
            node.children = (0..<fanOut).map { _ in
                Int.random(in: 0..<10, using: &rng) == 0
                    ? NSNull() as Any
                    : nodes[Int.random(in: 0..<count, using: &rng)] as Any
            }
        }
    }

    /// Independent reference: every node reachable within `maxDepth` hops, with its BFS depth.
    func reachable(maxDepth: Int) -> [Int: Int] {
        var depth: [Int: Int] = [root.code: 0]
        var frontier = [root]
        var level = 0
        while !frontier.isEmpty, level < max(0, maxDepth) {
            level += 1
            var next: [GraphError] = []
            for node in frontier {
                for child in Self.edges(of: node) where depth[child.code] == nil {
                    depth[child.code] = level
                    next.append(child)
                }
            }
            frontier = next
        }
        return depth
    }

    /// Whether any node at exactly `maxDepth` still has an edge to a node not yet reached.
    func hasEdgesBeyond(maxDepth: Int) -> Bool {
        let reached = reachable(maxDepth: maxDepth)
        return reached.contains { code, depth in
            depth == max(0, maxDepth) && Self.edges(of: nodes[code]).contains { reached[$0.code] == nil }
        }
    }

    /// A reached node with more error causes than the walk's fetch limit (`maxNodes + 1`) is
    /// one whose remainder the walk is entitled to leave unread — and to say so.
    func hasReachedNode(withMoreErrorCausesThan maxNodes: Int, maxDepth: Int) -> Bool {
        reachable(maxDepth: maxDepth).keys.contains { code in
            Self.errorCauseCount(of: nodes[code]) >= max(1, maxNodes) + 1
        }
    }

    func breakCycles() {
        for node in nodes {
            node.single = nil
            node.children = []
        }
    }

    /// Causes the walk would count against its fetch limit: errors only, junk excluded,
    /// duplicates included.
    private static func errorCauseCount(of node: GraphError) -> Int {
        (node.single is Error ? 1 : 0) + node.children.filter { $0 is Error }.count
    }

    private static func edges(of node: GraphError) -> [GraphError] {
        var result: [GraphError] = []
        if let single = node.single as? GraphError { result.append(single) }
        result.append(contentsOf: node.children.compactMap { $0 as? GraphError })
        return result
    }
}
