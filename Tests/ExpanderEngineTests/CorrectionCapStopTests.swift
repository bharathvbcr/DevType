import Foundation
import XCTest
@testable import ExpanderEngine

final class CorrectionCapStopTests: XCTestCase {
    private let rawTen = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
    private let keptSix = "alpha bravo charlie delta echo foxtrot"
    private let chatEndpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
    private let generateEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    func testLengthStopOnOpenAIAndBothOllamaApisFallsBackToRawTranscript() async throws {
        let ratio = Self.deletionRatio(raw: rawTen, candidate: keptSix)
        XCTAssertLessThanOrEqual(ratio, CorrectionPolicy.defaultMaxDeletionRatio)

        let openAI = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":"length"}]}
        """.utf8))
        XCTAssertEqual(openAI.stop, .length)
        XCTAssertEqual(openAI.text, keptSix)
        XCTAssertFalse(openAI.modelStopIsComplete)
        let openAIFinal = await finalize(
            rawText: rawTen,
            candidateText: openAI.text,
            modelStopIsComplete: openAI.modelStopIsComplete
        )
        assertFallback(openAIFinal, raw: rawTen)

        let chat = try OllamaCorrector.responseText(from: Data("""
        {"message":{"role":"assistant","content":"\(keptSix)"},"done":true,"done_reason":"length"}
        """.utf8), endpoint: chatEndpoint)
        XCTAssertEqual(chat.stop, .length)
        XCTAssertFalse(chat.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: chat.text, modelStopIsComplete: chat.modelStopIsComplete),
            raw: rawTen
        )

        let generate = try OllamaCorrector.responseText(from: Data("""
        {"response":"\(keptSix)","done":true,"done_reason":"length"}
        """.utf8), endpoint: generateEndpoint)
        XCTAssertEqual(generate.stop, .length)
        XCTAssertFalse(generate.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: generate.text, modelStopIsComplete: generate.modelStopIsComplete),
            raw: rawTen
        )

        let emptyLength = try OpenAICompatibleCorrector.responseText(from: Data(
            #"{"choices":[{"finish_reason":"length"}]}"#.utf8
        ))
        XCTAssertEqual(emptyLength.text, "")
        XCTAssertEqual(emptyLength.stop, .length)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: emptyLength.text, modelStopIsComplete: false),
            raw: rawTen
        )
    }

    func testOmittedFinishReasonAndDoneReasonAreNotAccepted() async throws {
        let openAI = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"}}]}
        """.utf8))
        XCTAssertEqual(openAI.stop, .omitted)
        XCTAssertFalse(openAI.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: openAI.text, modelStopIsComplete: openAI.modelStopIsComplete),
            raw: rawTen
        )

        let chat = try OllamaCorrector.responseText(from: Data("""
        {"message":{"role":"assistant","content":"\(keptSix)"},"done":true}
        """.utf8), endpoint: chatEndpoint)
        XCTAssertEqual(chat.stop, .omitted)
        XCTAssertFalse(chat.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: chat.text, modelStopIsComplete: chat.modelStopIsComplete),
            raw: rawTen
        )

        let generate = try OllamaCorrector.responseText(from: Data("""
        {"response":"\(keptSix)","done":true}
        """.utf8), endpoint: generateEndpoint)
        XCTAssertEqual(generate.stop, .omitted)
        XCTAssertFalse(generate.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: generate.text, modelStopIsComplete: generate.modelStopIsComplete),
            raw: rawTen
        )
    }

    func testOllamaDoneFalseWithStopReasonIsNotAccepted() async throws {
        let chat = try OllamaCorrector.responseText(from: Data("""
        {"message":{"role":"assistant","content":"\(keptSix)"},"done":false,"done_reason":"stop"}
        """.utf8), endpoint: chatEndpoint)
        XCTAssertEqual(chat.stop, .notFinished)
        XCTAssertFalse(chat.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: chat.text, modelStopIsComplete: chat.modelStopIsComplete),
            raw: rawTen
        )

        let generate = try OllamaCorrector.responseText(from: Data("""
        {"response":"\(keptSix)","done":false,"done_reason":"stop"}
        """.utf8), endpoint: generateEndpoint)
        XCTAssertEqual(generate.stop, .notFinished)
        XCTAssertFalse(generate.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: generate.text, modelStopIsComplete: generate.modelStopIsComplete),
            raw: rawTen
        )

        let missingContent = try OllamaCorrector.responseText(
            from: Data(#"{"done":false,"done_reason":"stop"}"#.utf8),
            endpoint: chatEndpoint
        )
        XCTAssertEqual(missingContent.text, "")
        XCTAssertEqual(missingContent.stop, .notFinished)
    }

    func testOpenAIFinishReasonVariantsLengthStopContentFilterEmptyAndNull() async throws {
        let length = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":"Length"}]}
        """.utf8))
        XCTAssertEqual(length.stop, .length)
        XCTAssertFalse(length.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: length.text, modelStopIsComplete: length.modelStopIsComplete),
            raw: rawTen
        )

        let stop = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":"STOP"}]}
        """.utf8))
        XCTAssertEqual(stop.stop, .finished)
        XCTAssertTrue(stop.modelStopIsComplete)
        let accepted = await finalize(
            rawText: rawTen,
            candidateText: stop.text,
            modelStopIsComplete: stop.modelStopIsComplete
        )
        XCTAssertEqual(accepted.text, keptSix)
        guard case .accepted = accepted.validationOutcome else {
            return XCTFail("Expected a finished STOP correction to be accepted, got \(accepted.validationOutcome)")
        }

        let paddedStop = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":" stop "}]}
        """.utf8))
        XCTAssertEqual(paddedStop.stop, .finished)

        let filter = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":"content_filter"}]}
        """.utf8))
        XCTAssertEqual(filter.stop, .notFinished)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: filter.text, modelStopIsComplete: filter.modelStopIsComplete),
            raw: rawTen
        )

        let toolCalls = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":"tool_calls"}]}
        """.utf8))
        XCTAssertEqual(toolCalls.stop, .notFinished)
        let functionCall = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":""},"finish_reason":"function_call"}]}
        """.utf8))
        XCTAssertEqual(functionCall.stop, .notFinished)
        XCTAssertEqual(functionCall.text, "")

        let empty = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":""}]}
        """.utf8))
        XCTAssertEqual(empty.stop, .omitted)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: empty.text, modelStopIsComplete: empty.modelStopIsComplete),
            raw: rawTen
        )

        let blank = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":" "}]}
        """.utf8))
        XCTAssertEqual(blank.stop, .omitted)

        let nullReason = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":null}]}
        """.utf8))
        XCTAssertEqual(nullReason.stop, .omitted)
        XCTAssertFalse(nullReason.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: nullReason.text, modelStopIsComplete: nullReason.modelStopIsComplete),
            raw: rawTen
        )
    }

    func testLengthStopRejectsWhenDeletionRatioIsWithinDefaultCeiling() async throws {
        let ratio = Self.deletionRatio(raw: rawTen, candidate: keptSix)
        XCTAssertEqual(ratio, 0.40, accuracy: 0.000_000_1)
        XCTAssertLessThanOrEqual(ratio, CorrectionPolicy.defaultMaxDeletionRatio)
        XCTAssertFalse(ratio > CorrectionPolicy.defaultMaxDeletionRatio)

        let length = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"\(keptSix)"},"finish_reason":"length"}],"usage":{"completion_tokens":1024}}
        """.utf8))
        XCTAssertEqual(length.stop, .length)
        let rejected = await finalize(
            rawText: rawTen,
            candidateText: length.text,
            modelStopIsComplete: length.modelStopIsComplete
        )
        assertFallback(rejected, raw: rawTen)
        XCTAssertNotEqual(rejected.text, keptSix)

        let finished = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(keptSix)"},"finish_reason":"stop"}]}
        """.utf8))
        XCTAssertEqual(finished.stop, .finished)
        let accepted = await finalize(
            rawText: rawTen,
            candidateText: finished.text,
            modelStopIsComplete: finished.modelStopIsComplete
        )
        XCTAssertEqual(accepted.text, keptSix)
        guard case .accepted = accepted.validationOutcome else {
            return XCTFail("The same deletion ratio must be accepted when finish_reason is stop, got \(accepted.validationOutcome)")
        }

        let ollama = try OllamaCorrector.responseText(from: Data("""
        {"model":"qwen","message":{"role":"assistant","content":"\(keptSix)"},"done":true,"done_reason":"length","eval_count":1024}
        """.utf8), endpoint: chatEndpoint)
        XCTAssertEqual(ollama.stop, .length)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: ollama.text, modelStopIsComplete: ollama.modelStopIsComplete),
            raw: rawTen
        )
    }

    func testFinishedShortCorrectionStillPassesAdditionAndDeletionCeilings() async throws {
        let rawFour = "alpha bravo charlie delta"
        let added = "alpha bravo charlie delta echo"
        let addition = Self.additionRatio(raw: rawFour, candidate: added)
        XCTAssertEqual(addition, 0.25, accuracy: 0.000_000_1)
        XCTAssertFalse(addition > CorrectionPolicy().maxAdditionRatio)

        let openAI = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(added)"},"finish_reason":"stop"}]}
        """.utf8))
        XCTAssertTrue(openAI.modelStopIsComplete)
        let addedFinal = await finalize(
            rawText: rawFour,
            candidateText: openAI.text,
            modelStopIsComplete: openAI.modelStopIsComplete
        )
        XCTAssertEqual(addedFinal.text, added)
        guard case .accepted = addedFinal.validationOutcome else {
            return XCTFail("Expected a short finished correction within the addition ceiling, got \(addedFinal.validationOutcome)")
        }

        let rawFive = "alpha bravo charlie delta echo"
        let shortened = "alpha bravo charlie delta"
        let deletion = Self.deletionRatio(raw: rawFive, candidate: shortened)
        XCTAssertEqual(deletion, 0.20, accuracy: 0.000_000_1)
        XCTAssertLessThanOrEqual(deletion, CorrectionPolicy.defaultMaxDeletionRatio)
        let chat = try OllamaCorrector.responseText(from: Data("""
        {"message":{"role":"assistant","content":"\(shortened)"},"done":true,"done_reason":"stop"}
        """.utf8), endpoint: chatEndpoint)
        XCTAssertEqual(chat.stop, .finished)
        let shortenedFinal = await finalize(
            rawText: rawFive,
            candidateText: chat.text,
            modelStopIsComplete: chat.modelStopIsComplete
        )
        XCTAssertEqual(shortenedFinal.text, shortened)
        guard case .accepted = shortenedFinal.validationOutcome else {
            return XCTFail("Expected a short finished correction within the deletion ceiling, got \(shortenedFinal.validationOutcome)")
        }

        let generate = try OllamaCorrector.responseText(from: Data("""
        {"response":"\(shortened)","done_reason":"STOP"}
        """.utf8), endpoint: generateEndpoint)
        XCTAssertEqual(generate.stop, .finished)
        let generateFinal = await finalize(
            rawText: rawFive,
            candidateText: generate.text,
            modelStopIsComplete: generate.modelStopIsComplete
        )
        XCTAssertEqual(generateFinal.text, shortened)
        guard case .accepted = generateFinal.validationOutcome else {
            return XCTFail("Expected Ollama generate stop to pass the deletion ceiling, got \(generateFinal.validationOutcome)")
        }

        let tooLong = await finalize(
            rawText: rawFour,
            candidateText: "alpha bravo charlie delta echo foxtrot",
            modelStopIsComplete: true
        )
        guard case .fallbackToRaw(let additionReason) = tooLong.validationOutcome else {
            return XCTFail("A finished correction over the addition ceiling must still fall back")
        }
        XCTAssertEqual(additionReason, .correctionHallucination)
        XCTAssertEqual(tooLong.text, rawFour)

        let tooShort = await finalize(
            rawText: rawTen,
            candidateText: "alpha bravo charlie delta echo",
            modelStopIsComplete: true
        )
        guard case .fallbackToRaw(let deletionReason) = tooShort.validationOutcome else {
            return XCTFail("A finished correction over the deletion ceiling must still fall back")
        }
        XCTAssertEqual(deletionReason, .correctionUnsupportedEdit)
        XCTAssertEqual(tooShort.text, rawTen)
    }

    func testUnicodeContentWithLengthStopFallsBackToRaw() async throws {
        let raw = "café naïve resume tokyo seoul alpha bravo charlie"
        let cut = "café naïve resume tokyo seoul"
        let ratio = Self.deletionRatio(raw: raw, candidate: cut)
        XCTAssertLessThanOrEqual(ratio, CorrectionPolicy.defaultMaxDeletionRatio)

        let openAI = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"choices":[{"message":{"content":"\(cut)"},"finish_reason":"length"}]}
        """.utf8))
        XCTAssertEqual(openAI.text, cut)
        XCTAssertEqual(openAI.stop, .length)
        assertFallback(
            await finalize(rawText: raw, candidateText: openAI.text, modelStopIsComplete: openAI.modelStopIsComplete),
            raw: raw
        )

        let generate = try OllamaCorrector.responseText(from: Data("""
        {"response":"\(cut) — 截断","done":true,"done_reason":"length","context":[1,2]}
        """.utf8), endpoint: generateEndpoint)
        XCTAssertEqual(generate.stop, .length)
        XCTAssertTrue(generate.text.contains("截断"))
        assertFallback(
            await finalize(rawText: raw, candidateText: generate.text, modelStopIsComplete: generate.modelStopIsComplete),
            raw: raw
        )
    }

    func testExtraJSONFieldsDoNotHideStopReason() async throws {
        let openAI = try OpenAICompatibleCorrector.responseText(from: Data("""
        {"id":"cmpl","finish_reason":"stop","model":"local","choices":[{"index":0,"logprobs":null,"finish_reason":"length","message":{"role":"assistant","content":"\(keptSix)","finish_reason":"stop"},"extra":{"done_reason":"stop"}}],"usage":{"completion_tokens":1024,"prompt_tokens":12}}
        """.utf8))
        XCTAssertEqual(openAI.text, keptSix)
        XCTAssertEqual(openAI.stop, .length)
        XCTAssertFalse(openAI.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: openAI.text, modelStopIsComplete: openAI.modelStopIsComplete),
            raw: rawTen
        )

        let chat = try OllamaCorrector.responseText(from: Data("""
        {"model":"qwen","created_at":"t","done":true,"done_reason":"length","total_duration":9,"message":{"role":"assistant","content":"\(keptSix)","done_reason":"stop"},"context":[1,2,3]}
        """.utf8), endpoint: chatEndpoint)
        XCTAssertEqual(chat.stop, .length)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: chat.text, modelStopIsComplete: chat.modelStopIsComplete),
            raw: rawTen
        )

        let generate = try OllamaCorrector.responseText(from: Data("""
        {"model":"qwen","done":true,"done_reason":"length","response":"\(keptSix)","context":[4],"stop":"stop"}
        """.utf8), endpoint: generateEndpoint)
        XCTAssertEqual(generate.stop, .length)
        XCTAssertEqual(generate.text, keptSix)
    }

    func testUnclassifiableOrInvalidBodiesStillThrow() throws {
        XCTAssertThrowsError(try OpenAICompatibleCorrector.responseText(from: Data("not-json".utf8))) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(try OpenAICompatibleCorrector.responseText(from: Data(#"{"choices":[]}"#.utf8))) { error in
            XCTAssertEqual((error as? VoiceFailure)?.code, .speechProtocolViolation)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: Data(#"{"finish_reason":"length","choices":[]}"#.utf8))
        ) { error in
            XCTAssertEqual((error as? VoiceFailure)?.code, .speechProtocolViolation)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: Data(#"{"choices":[{"message":{}}]}"#.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: Data(#"{"choices":[{"message":{"content":1},"finish_reason":"length"}]}"#.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: Data(#"{"choices":[{"message":{"content":null},"finish_reason":"stop"}]}"#.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }

        XCTAssertThrowsError(
            try OllamaCorrector.responseText(from: Data("{".utf8), endpoint: chatEndpoint)
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OllamaCorrector.responseText(from: Data(#"{"message":{"role":"assistant"}}"#.utf8), endpoint: chatEndpoint)
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OllamaCorrector.responseText(from: Data(#"{"done":true}"#.utf8), endpoint: generateEndpoint)
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }

        let lengthWithoutContent = try OllamaCorrector.responseText(
            from: Data(#"{"done_reason":"length"}"#.utf8),
            endpoint: generateEndpoint
        )
        XCTAssertEqual(lengthWithoutContent.stop, .length)
        XCTAssertEqual(lengthWithoutContent.text, "")
    }

    func testPersistedCandidateWithoutStopFlagDecodesAsComplete() throws {
        let legacy = Data("""
        {"text":"Hello","providerID":"p","modelVersion":"m","edits":[],"latencyMs":0,"promptVersion":"1.0","refusalDetected":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(CorrectionCandidate.self, from: legacy)
        XCTAssertEqual(decoded.text, "Hello")
        XCTAssertTrue(decoded.modelStopIsComplete)

        let incomplete = CorrectionCandidate(
            text: keptSix,
            providerID: "p",
            modelVersion: "m",
            modelStopIsComplete: false
        )
        let encoded = try JSONEncoder().encode(incomplete)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["modelStopIsComplete"] as? Bool, false)
        let roundTrip = try JSONDecoder().decode(CorrectionCandidate.self, from: encoded)
        XCTAssertFalse(roundTrip.modelStopIsComplete)
        XCTAssertEqual(roundTrip, incomplete)

        let explicitNull = Data("""
        {"text":"Hello","providerID":"p","modelVersion":"m","edits":[],"latencyMs":1.5,"promptVersion":"1.0","refusalDetected":false,"modelStopIsComplete":null}
        """.utf8)
        let nullDecoded = try JSONDecoder().decode(CorrectionCandidate.self, from: explicitNull)
        XCTAssertTrue(nullDecoded.modelStopIsComplete)
    }

    /// Same-build comparison against the pre-fix decoder shape (content only, no stop field).
    /// There is no pre-fix binary in this tree; both loops run in this debug process.
    func testFixedPayloadDecodeCostAgainstPreviousDecoderShape() throws {
        let payload = Data(#"""
        {"id":"cmpl","choices":[{"index":0,"message":{"role":"assistant","content":"Compatible output"},"finish_reason":"stop"}],"usage":{"completion_tokens":3}}
        """#.utf8)

        struct PreviousChat: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let previousText = try JSONDecoder().decode(PreviousChat.self, from: payload).choices[0].message.content
        let current = try OpenAICompatibleCorrector.responseText(from: payload)
        XCTAssertEqual(current.text, previousText)
        XCTAssertEqual(current.stop, .finished)

        let rounds = 8
        let iterations = 4000
        var previousNanos: [Double] = []
        var currentNanos: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<200 {
            _ = try JSONDecoder().decode(PreviousChat.self, from: payload).choices[0].message.content
            _ = try OpenAICompatibleCorrector.responseText(from: payload).text
        }
        for _ in 0..<rounds {
            var previousCount = 0
            let previous = clock.measure {
                for _ in 0..<iterations {
                    let decoded = try! JSONDecoder().decode(PreviousChat.self, from: payload)
                    previousCount &+= decoded.choices[0].message.content.utf8.count
                }
            }
            var currentCount = 0
            let now = clock.measure {
                for _ in 0..<iterations {
                    let decoded = try! OpenAICompatibleCorrector.responseText(from: payload)
                    currentCount &+= decoded.text.utf8.count
                }
            }
            XCTAssertEqual(previousCount, iterations * previousText.utf8.count)
            XCTAssertEqual(currentCount, iterations * previousText.utf8.count)
            previousNanos.append(Self.nanoseconds(previous))
            currentNanos.append(Self.nanoseconds(now))
        }

        let previousMin = previousNanos.min() ?? 0
        let currentMin = currentNanos.min() ?? 0
        let ratio = previousMin == 0 ? 0 : currentMin / previousMin
        print(
            "correction-decode bench iterations=\(iterations) previousMinNs=\(previousMin) currentMinNs=\(currentMin) ratio=\(ratio)"
        )
        XCTAssertGreaterThan(previousMin, 0)
        XCTAssertGreaterThan(currentMin, 0)
    }

    private func finalize(
        rawText: String,
        candidateText: String,
        modelStopIsComplete: Bool
    ) async -> FinalTranscript {
        let raw = RawTranscript(
            text: rawText,
            localeIdentifier: "en_US",
            providerID: "test.speech",
            modelVersion: "1"
        )
        let candidate = CorrectionCandidate(
            text: candidateText,
            providerID: "test.length-stop",
            modelVersion: "1",
            modelStopIsComplete: modelStopIsComplete
        )
        return await CorrectionPipeline.execute(
            rawTranscript: raw,
            corrector: ScriptedCorrector(candidate: candidate),
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .localNetworkOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
    }

    private func assertFallback(
        _ final: FinalTranscript,
        raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(final.text, raw, file: file, line: line)
        guard case .fallbackToRaw(let reason) = final.validationOutcome else {
            XCTFail("Expected fallbackToRaw, got \(final.validationOutcome)", file: file, line: line)
            return
        }
        XCTAssertEqual(reason, .correctionUnsupportedEdit, file: file, line: line)
    }

    private static func deletionRatio(raw: String, candidate: String) -> Double {
        let rawCount = Double(raw.split(whereSeparator: \.isWhitespace).count)
        let candidateCount = Double(candidate.split(whereSeparator: \.isWhitespace).count)
        return max(0, (rawCount - candidateCount) / rawCount)
    }

    private static func additionRatio(raw: String, candidate: String) -> Double {
        let rawCount = Double(raw.split(whereSeparator: \.isWhitespace).count)
        let candidateCount = Double(candidate.split(whereSeparator: \.isWhitespace).count)
        return max(0, (candidateCount - rawCount) / rawCount)
    }

    private static func nanoseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000_000_000 + Double(parts.attoseconds) / 1_000_000_000
    }
}

private struct ScriptedCorrector: TranscriptCorrector {
    let candidate: CorrectionCandidate
    let descriptor = CorrectionProviderDescriptor(
        id: "test.length-stop",
        displayName: "Length stop",
        modelVersion: "1",
        privacyRoute: .localNetworkOnly,
        supportsStructuredOutput: false
    )

    func probe() async -> ProviderReadiness {
        .ready(ProviderEvidence(
            providerID: descriptor.id,
            modelVersion: descriptor.modelVersion,
            probeTimestamp: Date(),
            capabilities: []
        ))
    }

    func correct(_ request: CorrectionRequest) async throws -> CorrectionCandidate {
        candidate
    }

    func cancel(sessionID: VoiceSessionID) async {}
}
