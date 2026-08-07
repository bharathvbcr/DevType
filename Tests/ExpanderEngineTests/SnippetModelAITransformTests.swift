import XCTest
@testable import ExpanderEngine

final class SnippetModelAITransformTests: XCTestCase {
    func testSnippetModelDecodesLegacyJSONWithoutAITransform() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Plain",
            "triggerKeyword": ":hi",
            "replacementText": "Hello",
            "isCaseSensitive": false,
            "requireWordBoundary": true,
            "isPlainText": true,
            "enabled": true,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "updatedAt": Date().timeIntervalSinceReferenceDate,
            "usageCount": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(SnippetModel.self, from: data)
        XCTAssertEqual(decoded.aiTransform, "")
        XCTAssertEqual(decoded.triggerKeyword, ":hi")
        XCTAssertEqual(decoded.replacementText, "Hello")
    }

    func testSnippetModelAITransformRoundTrip() throws {
        let snippet = SnippetModel(
            title: "Proof",
            triggerKeyword: ";proof",
            replacementText: "",
            aiTransform: "proofread"
        )
        let data = try JSONEncoder().encode(snippet)
        let decoded = try JSONDecoder().decode(SnippetModel.self, from: data)
        XCTAssertEqual(decoded, snippet)
        XCTAssertEqual(decoded.aiTransform, "proofread")
    }
}
