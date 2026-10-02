import Foundation
import XCTest
@testable import ExpanderEngine

/// The on-device model service refusing work under system pressure (ModelManagerError 1013).
///
/// `observedRefusal()` is the exact error `LanguageModelSession.respond` threw on this machine
/// on 2026-10-01 while `modelmanagerd` logged `Not executed due to current system state
/// ["CriticalMemoryPressure"]`. Before the classifier, `mapGenerationError` returned it as
/// `.unknown("…SensitiveContentAnalysisML error 15.")` — which is what users saw.
final class AISystemDeferralTests: XCTestCase {

    static func observedRefusal() -> NSError {
        let leaf = NSError(
            domain: "ModelManagerServices.ModelManagerError",
            code: 1013,
            userInfo: [NSMultipleUnderlyingErrorsKey: [Any]()]
        )
        let backend = NSError(
            domain: "SensitiveContentAnalysisML.CombinedTextSanitizerBackend.BackendError",
            code: 1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [leaf]]
        )
        let sanitizer = NSError(
            domain: "com.apple.SensitiveContentAnalysisML",
            code: 15,
            userInfo: [NSMultipleUnderlyingErrorsKey: [backend]]
        )
        return NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The operation couldn’t be completed. (com.apple.SensitiveContentAnalysisML error 15.)",
                NSMultipleUnderlyingErrorsKey: [sanitizer],
            ]
        )
    }

    // MARK: - Classifier

    func testObservedRefusalIsASystemDeferral() {
        XCTAssertTrue(AITransformError.isSystemDeferral(Self.observedRefusal()))
    }

    func testRefusalAtTheRootIsRecognised() {
        let bare = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        XCTAssertTrue(AITransformError.isSystemDeferral(bare))
    }

    /// Generation reports the same refusal through TokenGenerator rather than the sanitizer,
    /// so the wrapper differs. Only the leaf is matched.
    func testRefusalUnderADifferentWrapperIsRecognised() {
        let leaf = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        let wrapped = NSError(
            domain: "SomeFutureWrapper",
            code: 77,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "Middle", code: 2, userInfo: [NSUnderlyingErrorKey: leaf])]
        )
        XCTAssertTrue(AITransformError.isSystemDeferral(wrapped))
    }

    func testRefusalInsideASwiftErrorIsRecognised() {
        let leaf = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        XCTAssertTrue(AITransformError.isSystemDeferral(WrappingSwiftError(underlying: leaf)))
    }

    func testRefusalAmongSiblingsAndJunkIsRecognised() {
        let root = NSError(domain: "FoundationModels.LanguageModelError", code: -1, userInfo: [
            NSMultipleUnderlyingErrorsKey: [
                "junk", NSError(domain: "Other", code: 1),
                NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013),
            ] as [Any],
        ])
        XCTAssertTrue(AITransformError.isSystemDeferral(root))
    }

    /// Nothing near the signal may be mistaken for it: the wrapper chain without its leaf, the
    /// right domain with another code, the right code in another domain.
    func testNearMissesAreNotSystemDeferrals() {
        let wrapperOnly = NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [
                NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15),
            ]]
        )
        let cases: [Error] = [
            wrapperOnly,
            NSError(domain: "ModelManagerServices.ModelManagerError", code: 1012),
            NSError(domain: "ModelManagerServices.ModelManagerError", code: 1014),
            NSError(domain: "ModelManagerServices.ModelManagerError", code: -1013),
            NSError(domain: "ModelManagerServices.ModelManagerErrorX", code: 1013),
            NSError(domain: "modelmanagerservices.modelmanagererror", code: 1013),
            NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 1013),
            NSError(domain: NSCocoaErrorDomain, code: 1013),
            CancellationError(),
            SampleSwiftError.boom,
        ]
        for error in cases {
            XCTAssertFalse(AITransformError.isSystemDeferral(error), "\(error)")
        }
    }

    /// A refusal buried past the walk's caps is not claimed: the classifier only ever says
    /// "deferred" for a leaf it actually read.
    func testRefusalBeyondTheDepthCapIsNotClaimed() {
        var current = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        for code in 0..<ErrorGraph.defaultMaxDepth + 1 {
            current = NSError(domain: "wrap", code: code, userInfo: [NSUnderlyingErrorKey: current])
        }
        XCTAssertFalse(AITransformError.isSystemDeferral(current))
    }

    func testCyclicErrorGraphTerminates() {
        let a = GraphError(domain: "a", code: 1)
        let b = GraphError(domain: "b", code: 2)
        a.children = [b]
        b.children = [a]
        defer { a.children = []; b.children = [] }
        XCTAssertFalse(AITransformError.isSystemDeferral(a))

        b.children = [a, NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)]
        XCTAssertTrue(AITransformError.isSystemDeferral(a))
    }

    /// Seeded random graphs with the refusal planted (or not) at a random node: the classifier
    /// agrees with "is the planted node within the walk".
    func testRandomGraphsWithAPlantedRefusal() {
        var rng = SplitMix64(seed: 1013)
        for iteration in 0..<1_000 {
            let graph = RandomGraph(rng: &rng)
            defer { graph.breakCycles() }
            let host = graph.nodes[Int.random(in: 0..<graph.nodes.count, using: &rng)]
            let plant = Bool.random(using: &rng)
            if plant {
                host.children.append(NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013))
            }
            let walk = ErrorGraph.walk(graph.root)
            let classified = AITransformError.isSystemDeferral(graph.root)
            let hostReached = walk.nodes.contains { $0.code == host.code }

            if !plant {
                XCTAssertFalse(classified, "iteration \(iteration): nothing was planted")
            } else if hostReached, !walk.truncated {
                XCTAssertTrue(classified, "iteration \(iteration): planted leaf was in reach")
            }
            if classified {
                XCTAssertTrue(plant, "iteration \(iteration): classified without a plant")
            }
        }
    }

    // MARK: - Mapping (the path users hit)

    #if canImport(FoundationModels)

    func testObservedRefusalMapsToDeferredBySystemAndIsRecordedAsSuch() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26+") }
        let start = Date()

        let mapped = AITextTransformer.mapGenerationError(
            Self.observedRefusal(),
            kind: .proofread,
            input: "hello"
        )

        XCTAssertEqual(mapped, .deferredBySystem)
        // The store is a 20-entry ring, so assert on the newest entry rather than a count.
        let newest = try XCTUnwrap(AIDiagnosticsStore.shared.recentFailures().last)
        XCTAssertGreaterThanOrEqual(newest.at, start)
        XCTAssertEqual(newest.error, "deferredBySystem", "must not be filed as \"unknown\"")
        XCTAssertEqual(newest.kind, AITransformKind.proofread.rawValue)
    }

    /// The pre-fix behaviour is kept for everything that is not the refusal.
    func testOtherFrameworkErrorsStillMapToUnknown() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26+") }
        let other = NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "something else"]
        )
        guard case .unknown = AITextTransformer.mapGenerationError(other, kind: .proofread, input: "x") else {
            return XCTFail("a non-refusal framework error must stay .unknown")
        }
    }

    func testCancellationStillWinsOverEverything() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26+") }
        XCTAssertEqual(
            AITextTransformer.mapGenerationError(CancellationError(), kind: .proofread, input: "x"),
            .discarded
        )
    }

    #endif

    // MARK: - Strings

    func testDeferredBySystemHasItsOwnKeyInEveryLanguage() {
        let key = AITransformError.deferredBySystem.localizationKey
        XCTAssertEqual(key, "ai.error.deferredBySystem")
        for language in AppLanguage.concreteCases {
            let text = LocalizationManager.stringTable(for: language)[key]
            XCTAssertNotNil(text, "missing in \(language.rawValue)")
            XCTAssertFalse(text?.contains("%") ?? true, "takes no format arguments")
        }
    }
}
