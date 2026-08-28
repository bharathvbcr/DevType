import XCTest
@testable import ExpanderEngine

final class TranscriptionValidationGateTests: XCTestCase {

    func testArtifactStripping() {
        // Strip markdown code fences
        let fenced = "```\nThis is a transcript\n```"
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts(fenced), "This is a transcript")

        let fencedWithLang = "```swift\nlet x = 1\n```"
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts(fencedWithLang), "let x = 1")

        // Strip labels
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts("CLEAN: Hello world"), "Hello world")
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts("Clean: Hello world"), "Hello world")
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts("Transcript: Hello world"), "Hello world")
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts("TRANSCRIPT: Hello world"), "Hello world")

        // Strip surrounding quotes
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts("\"Hello world\""), "Hello world")

        // Plain text passes through unchanged
        XCTAssertEqual(TranscriptionValidationGate.stripArtifacts("Hello world"), "Hello world")
    }

    func testIdenticalTextAccepted() {
        let raw = "Let's meet at 2:00 PM tomorrow to discuss the project."
        let cleaned = "Let's meet at 2:00 PM tomorrow to discuss the project."
        let verdict = TranscriptionValidationGate.validate(raw: raw, cleaned: cleaned)
        XCTAssertTrue(verdict.accepted)
        XCTAssertNil(verdict.reason)
    }

    func testSelfCorrectionCollapseAccepted() {
        // Legitimate self-correction collapse can shorten text substantially
        let raw = "Umm let's meet at 1:00 PM actually no make that 2:00 PM tomorrow."
        let cleaned = "Let's meet at 2:00 PM tomorrow."
        let verdict = TranscriptionValidationGate.validate(raw: raw, cleaned: cleaned)
        XCTAssertTrue(verdict.accepted, "Legitimate self-correction collapse must be accepted: \(verdict.reason ?? "")")
    }

    func testSevereLengthExplosionRejected() {
        let raw = "Hello world"
        let hallucinated = "Hello world, I am an AI assistant and I am here to help you write code and transcribe audio perfectly with lots of extra text."
        let verdict = TranscriptionValidationGate.validate(raw: raw, cleaned: hallucinated)
        XCTAssertFalse(verdict.accepted)
        XCTAssertNotNil(verdict.reason)
    }

    func testSevereLengthCollapseRejected() {
        let raw = "We have a very long meeting transcript discussing architectural requirements and deployment timelines for Q3 and Q4."
        let collapsed = "Meeting."
        let verdict = TranscriptionValidationGate.validate(raw: raw, cleaned: collapsed)
        XCTAssertFalse(verdict.accepted)
        XCTAssertNotNil(verdict.reason)
    }

    func testAnswerModeDivergenceRejected() {
        // Model answering the dictation with new content instead of transcribing/cleaning it
        let raw = "How do you configure an nginx reverse proxy?"
        let answered = "To configure nginx as a reverse proxy, edit nginx.conf and add a proxy_pass directive."
        let verdict = TranscriptionValidationGate.validate(raw: raw, cleaned: answered)
        XCTAssertFalse(verdict.accepted)
        XCTAssertNotNil(verdict.reason)
    }

    func testEmptyInputs() {
        XCTAssertTrue(TranscriptionValidationGate.validate(raw: "", cleaned: "").accepted)
        XCTAssertFalse(TranscriptionValidationGate.validate(raw: "Hello", cleaned: "").accepted)
        XCTAssertFalse(TranscriptionValidationGate.validate(raw: "", cleaned: "Hello").accepted)
    }
}
