import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// §8.2: one `SwallowedKey` value instead of four parameters through nine signatures.
final class SwallowedKeyAdoptionTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        SourceContractTests.strippingComments(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        ))
    }

    /// The legacy list survived beside the struct for a release "verbatim"; a second spelling
    /// of the same contract is how one path drifts from the other. It is gone everywhere that
    /// carries the key — only the pure unit counters keep their single `swallowedFinalKey` Bool.
    func testTheLegacyParameterListIsGone() throws {
        for path in [
            "Sources/ExpanderEngine/Engine/EventTapEngine.swift",
            "Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift",
            "Sources/ExpanderEngine/Engine/ErasePlan.swift",
            "Sources/DevTypeAppCore/AppDelegate.swift",
            "Sources/DevTypeAppCore/TestExpansionLab.swift"
        ] {
            let text = try source(path)
            for legacy in ["swallowedUnicode", "swallowedKeyCode", "swallowedFlags"] {
                XCTAssertFalse(text.contains(legacy), "\(path) still carries \(legacy)")
            }
        }
        let tap = try source("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        XCTAssertFalse(tap.contains("swallowedFinalKey"), "didSwallow lives in SwallowedKey")
        let pipeline = try source("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        XCTAssertFalse(pipeline.contains("reinjectSwallowedKey(\n        unicode:"),
                       "The four-value reinject overload is gone")
    }

    /// The refuse path used to hard-code `mustReinjectOnRefuse(didSwallow: true)` and was safe on
    /// the prefix-debounce fire (which swallows nothing) only because that path's payload was
    /// empty. The decision now comes from the key itself.
    func testTheTapRefusePathAsksTheKeyWhetherItWasSwallowed() throws {
        let tap = try source("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        XCTAssertFalse(tap.contains("mustReinjectOnRefuse(didSwallow: true)"))
        let refuse = try XCTUnwrap(tap.range(of: "private func refuseAfterSwallow("))
        let body = tap[refuse.upperBound...].prefix(600)
        XCTAssertTrue(body.contains("if swallowed.mustReinjectOnRefuse"))
    }

    func testAKeyThatWasLetThroughIsNeverOwedBack() {
        // A payload alone does not make a key owed: the held fire passes its key through.
        let held = SwallowedKey(didSwallow: false, unicode: "x", keyCode: 7, flags: [])
        XCTAssertTrue(held.hasPayload)
        XCTAssertFalse(held.mustReinjectOnRefuse)
        XCTAssertFalse(SwallowedKey.notSwallowed.mustReinjectOnRefuse)
        XCTAssertTrue(SwallowedKey(didSwallow: true, unicode: "x").mustReinjectOnRefuse)
    }

    func testErasePlanReadsTheSwallowedKey() {
        let swallowed = ErasePlan.forMatch(
            matchedTrigger: ";sig", terminator: "", swallowed: SwallowedKey(didSwallow: true, unicode: "g")
        )
        XCTAssertEqual(swallowed.expectedText, ";si")
        let letThrough = ErasePlan.forMatch(
            matchedTrigger: ";sig", terminator: "", swallowed: SwallowedKey(didSwallow: false, unicode: "g")
        )
        XCTAssertEqual(letThrough.expectedText, ";sig", "A key that reached the field is erased with it")
    }
}
