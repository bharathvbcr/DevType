import XCTest
@testable import ExpanderEngine

final class GeminiTranscriptionClientTests: XCTestCase {

    func testMissingAPIKeyThrowsError() async {
        let client = GeminiTranscriptionClient()
        let dummyData = Data([0x00, 0x01, 0x02])

        do {
            _ = try await client.transcribe(
                audioData: dummyData,
                mimeType: "audio/flac",
                audioDurationSeconds: 1.0,
                steeringPrompt: "Transcribe",
                apiKey: ""
            )
            XCTFail("Expected noAPIKey error")
        } catch let error as GeminiTranscriptionError {
            XCTAssertEqual(error, .noAPIKey)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testErrorEnumEquality() {
        XCTAssertEqual(GeminiTranscriptionError.noAPIKey, GeminiTranscriptionError.noAPIKey)
        XCTAssertEqual(GeminiTranscriptionError.invalidAPIKey, GeminiTranscriptionError.invalidAPIKey)
        XCTAssertEqual(GeminiTranscriptionError.modelAccessDenied, GeminiTranscriptionError.modelAccessDenied)
        XCTAssertEqual(GeminiTranscriptionError.rateLimited, GeminiTranscriptionError.rateLimited)
        XCTAssertEqual(GeminiTranscriptionError.quotaExhausted, GeminiTranscriptionError.quotaExhausted)
        XCTAssertEqual(GeminiTranscriptionError.timeout, GeminiTranscriptionError.timeout)
        XCTAssertEqual(GeminiTranscriptionError.safetyBlocked, GeminiTranscriptionError.safetyBlocked)
        XCTAssertEqual(GeminiTranscriptionError.emptyTranscript, GeminiTranscriptionError.emptyTranscript)
        XCTAssertEqual(GeminiTranscriptionError.networkError("conn"), GeminiTranscriptionError.networkError("conn"))
    }
}
