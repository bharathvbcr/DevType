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
    }

    func testAPIKeyValidationResultProperties() {
        let valid = APIKeyValidationResult.valid(modelName: "gemini-3.5-transcribe")
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.userMessage, "Key Valid & Saved")

        let invalid = APIKeyValidationResult.invalidKey(reason: "API key is invalid")
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.userMessage, "API key is invalid")

        let rateLimited = APIKeyValidationResult.rateLimited
        XCTAssertFalse(rateLimited.isValid)
        XCTAssertEqual(rateLimited.userMessage, "API Rate Limited (429)")

        let quota = APIKeyValidationResult.quotaExhausted
        XCTAssertFalse(quota.isValid)
        XCTAssertEqual(quota.userMessage, "Quota Exhausted")

        let network = APIKeyValidationResult.networkError(reason: "No connection")
        XCTAssertFalse(network.isValid)
        XCTAssertEqual(network.userMessage, "Network Error: No connection")
    }

    func testEmptyAndMalformedAPIKeyValidation() async {
        let client = GeminiTranscriptionClient()

        let emptyResult = await client.validateAPIKeyDetailed("")
        XCTAssertFalse(emptyResult.isValid)
        if case .invalidKey(let reason) = emptyResult {
            XCTAssertTrue(reason.contains("empty"))
        } else {
            XCTFail("Expected invalidKey for empty input")
        }

        let whitespaceResult = await client.validateAPIKeyDetailed("   ")
        XCTAssertFalse(whitespaceResult.isValid)

        let malformedResult = await client.validateAPIKeyDetailed("key with spaces")
        XCTAssertFalse(malformedResult.isValid)

        let shortResult = await client.validateAPIKeyDetailed("short")
        XCTAssertFalse(shortResult.isValid)
    }
}
