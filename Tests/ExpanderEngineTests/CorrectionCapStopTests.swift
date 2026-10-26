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

    func testHostileOpenAIFinishReasonsFirstChoiceAndMissingContent() async throws {
        for reason in ["length", "Length", "LENGTH", " length ", "\nLength\t"] {
            let decoded = try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "id": "cmpl",
                "finish_reason": "stop",
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": keptSix, "finish_reason": "stop"],
                    "finish_reason": reason,
                    "extra": ["done_reason": "stop"]
                ]],
                "usage": ["completion_tokens": 1024]
            ]))
            XCTAssertEqual(decoded.text, keptSix, reason)
            XCTAssertEqual(decoded.stop, .length, reason)
            XCTAssertFalse(decoded.modelStopIsComplete, reason)
            let final = await finalize(
                rawText: rawTen,
                candidateText: decoded.text,
                modelStopIsComplete: decoded.modelStopIsComplete
            )
            assertFallback(final, raw: rawTen)
            XCTAssertNotEqual(final.text, keptSix, reason)
        }

        for reason in ["stop", "STOP", "Stop", " stop ", "\tSTOP\n"] {
            let decoded = try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["message": ["content": keptSix], "finish_reason": reason]]
            ]))
            XCTAssertEqual(decoded.stop, .finished, reason)
            XCTAssertTrue(decoded.modelStopIsComplete, reason)
            XCTAssertEqual(decoded.text, keptSix, reason)
        }

        let nullReason = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": keptSix], "finish_reason": NSNull()]]
        ]))
        XCTAssertEqual(nullReason.stop, .omitted)
        XCTAssertFalse(nullReason.modelStopIsComplete)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: nullReason.text, modelStopIsComplete: nullReason.modelStopIsComplete),
            raw: rawTen
        )

        let missingReason = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": keptSix], "logprobs": NSNull()]]
        ]))
        XCTAssertEqual(missingReason.stop, .omitted)
        assertFallback(
            await finalize(rawText: rawTen, candidateText: missingReason.text, modelStopIsComplete: missingReason.modelStopIsComplete),
            raw: rawTen
        )

        for reason in ["", " ", "\n", "\t"] {
            let decoded = try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["message": ["content": keptSix], "finish_reason": reason]]
            ]))
            XCTAssertEqual(decoded.stop, .omitted, "blank reason \(reason.debugDescription)")
            XCTAssertFalse(decoded.modelStopIsComplete)
        }

        for reason in ["content_filter", "tool_calls", "function_call", "st op", "stop\u{0000}", "max_tokens", "eos", "length_limit"] {
            let decoded = try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["message": ["content": keptSix], "finish_reason": reason]]
            ]))
            XCTAssertNotEqual(decoded.stop, .finished, reason)
            XCTAssertFalse(decoded.modelStopIsComplete, reason)
            assertFallback(
                await finalize(rawText: rawTen, candidateText: decoded.text, modelStopIsComplete: decoded.modelStopIsComplete),
                raw: rawTen
            )
        }

        let firstIsLength = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [
                ["index": 0, "message": ["role": "assistant", "content": keptSix], "finish_reason": "length"],
                ["index": 1, "message": ["role": "assistant", "content": rawTen], "finish_reason": "stop"]
            ]
        ]))
        XCTAssertEqual(firstIsLength.text, keptSix)
        XCTAssertEqual(firstIsLength.stop, .length)
        XCTAssertFalse(firstIsLength.modelStopIsComplete)
        let firstLengthFinal = await finalize(
            rawText: rawTen,
            candidateText: firstIsLength.text,
            modelStopIsComplete: firstIsLength.modelStopIsComplete
        )
        assertFallback(firstLengthFinal, raw: rawTen)
        XCTAssertEqual(firstLengthFinal.text, rawTen)
        XCTAssertNotEqual(firstLengthFinal.correctionCandidate?.text, rawTen)

        let firstIsStop = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [
                ["index": 0, "message": ["content": keptSix], "finish_reason": "stop"],
                ["index": 1, "message": ["content": "nope nope nope"], "finish_reason": "LENGTH"]
            ]
        ]))
        XCTAssertEqual(firstIsStop.text, keptSix)
        XCTAssertEqual(firstIsStop.stop, .finished)
        let firstStopFinal = await finalize(
            rawText: rawTen,
            candidateText: firstIsStop.text,
            modelStopIsComplete: firstIsStop.modelStopIsComplete
        )
        XCTAssertEqual(firstStopFinal.text, keptSix)
        guard case .accepted = firstStopFinal.validationOutcome else {
            return XCTFail("The first choice is stop; a later length choice must not reject it, got \(firstStopFinal.validationOutcome)")
        }

        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: try Self.json(["choices": [], "finish_reason": "stop"]))
        ) { error in
            XCTAssertEqual((error as? VoiceFailure)?.code, .speechProtocolViolation)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: Data("not-json".utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }

        let nullContentLength = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": NSNull()], "finish_reason": "length"]]
        ]))
        XCTAssertEqual(nullContentLength.text, "")
        XCTAssertEqual(nullContentLength.stop, .length)
        XCTAssertFalse(nullContentLength.modelStopIsComplete)
        let nullContentFinal = await finalize(
            rawText: rawTen,
            candidateText: nullContentLength.text,
            modelStopIsComplete: nullContentLength.modelStopIsComplete
        )
        assertFallback(nullContentFinal, raw: rawTen)
        XCTAssertNotEqual(nullContentFinal.validationOutcome, .fallbackToRaw(reason: .correctionRefusal))
        XCTAssertNotEqual(nullContentFinal.validationOutcome, .accepted(metrics: [:]))

        let absentMessageLength = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["finish_reason": "LENGTH", "index": 0]]
        ]))
        XCTAssertEqual(absentMessageLength.text, "")
        XCTAssertEqual(absentMessageLength.stop, .length)
        assertFallback(
            await finalize(
                rawText: rawTen,
                candidateText: absentMessageLength.text,
                modelStopIsComplete: absentMessageLength.modelStopIsComplete
            ),
            raw: rawTen
        )

        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["message": ["role": "assistant"]]]
            ]))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["message": ["content": NSNull()], "finish_reason": "stop"]]
            ]))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["message": ["content": NSNull()]]]
            ]))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try OpenAICompatibleCorrector.responseText(from: try Self.json([
                "choices": [["finish_reason": "stop"]]
            ]))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }

        let routingShape = try OpenAICompatibleCorrector.responseText(
            from: Data(#"{"choices":[{"message":{"content":"Compatible output"}}]}"#.utf8)
        )
        XCTAssertEqual(routingShape.text, "Compatible output")
        XCTAssertEqual(routingShape.stop, .omitted)
        XCTAssertFalse(routingShape.modelStopIsComplete)
        assertFallback(
            await finalize(
                rawText: "Compatible output",
                candidateText: routingShape.text,
                modelStopIsComplete: routingShape.modelStopIsComplete
            ),
            raw: "Compatible output"
        )
    }

    func testHostileOllamaChatAndGenerateDoneMatrix() async throws {
        let rawFive = "alpha bravo charlie delta echo"
        let shortened = "alpha bravo charlie delta"

        let lengthBodies: [(URL, [String: Any], String)] = [
            (chatEndpoint, [
                "message": ["role": "assistant", "content": keptSix],
                "done": true,
                "done_reason": "length"
            ], "chat length"),
            (generateEndpoint, [
                "response": keptSix,
                "done": true,
                "done_reason": "LENGTH"
            ], "generate LENGTH"),
            (chatEndpoint, [
                "message": ["role": "assistant", "content": keptSix, "done_reason": "stop"],
                "done": true,
                "done_reason": " Length ",
                "context": [1, 2]
            ], "chat padded Length"),
            (generateEndpoint, [
                "response": keptSix,
                "done": false,
                "done_reason": "length"
            ], "generate done false length")
        ]
        for (endpoint, body, label) in lengthBodies {
            let decoded = try OllamaCorrector.responseText(from: try Self.json(body), endpoint: endpoint)
            XCTAssertEqual(decoded.text, keptSix, label)
            XCTAssertEqual(decoded.stop, .length, label)
            XCTAssertFalse(decoded.modelStopIsComplete, label)
            assertFallback(
                await finalize(rawText: rawTen, candidateText: decoded.text, modelStopIsComplete: decoded.modelStopIsComplete),
                raw: rawTen
            )
        }

        let equalRaw = "same words here"
        for (endpoint, body) in [
            (chatEndpoint, [
                "message": ["role": "assistant", "content": equalRaw],
                "done": false,
                "done_reason": "stop"
            ] as [String: Any]),
            (generateEndpoint, [
                "response": equalRaw,
                "done": false,
                "done_reason": "STOP"
            ] as [String: Any])
        ] {
            let decoded = try OllamaCorrector.responseText(from: try Self.json(body), endpoint: endpoint)
            XCTAssertEqual(decoded.stop, .notFinished)
            XCTAssertFalse(decoded.modelStopIsComplete)
            assertFallback(
                await finalize(rawText: equalRaw, candidateText: decoded.text, modelStopIsComplete: decoded.modelStopIsComplete),
                raw: equalRaw
            )
        }

        let omittedBodies: [(URL, [String: Any])] = [
            (chatEndpoint, ["message": ["role": "assistant", "content": keptSix], "done": true]),
            (generateEndpoint, ["response": keptSix, "done": true]),
            (chatEndpoint, ["message": ["role": "assistant", "content": keptSix], "done": true, "done_reason": NSNull()]),
            (generateEndpoint, ["response": keptSix, "done": true, "done_reason": ""]),
            (generateEndpoint, ["response": keptSix, "done": true, "done_reason": " \n"]),
            (chatEndpoint, ["message": ["content": keptSix], "done": true, "done_reason": "   "])
        ]
        for (endpoint, body) in omittedBodies {
            let decoded = try OllamaCorrector.responseText(from: try Self.json(body), endpoint: endpoint)
            XCTAssertEqual(decoded.stop, .omitted)
            XCTAssertFalse(decoded.modelStopIsComplete)
            assertFallback(
                await finalize(rawText: rawTen, candidateText: decoded.text, modelStopIsComplete: decoded.modelStopIsComplete),
                raw: rawTen
            )
        }

        let routingOllama = try OllamaCorrector.responseText(
            from: Data(#"{"message":{"role":"assistant","content":"Clean output"},"done":true}"#.utf8),
            endpoint: chatEndpoint
        )
        XCTAssertEqual(routingOllama.text, "Clean output")
        XCTAssertEqual(routingOllama.stop, .omitted)
        assertFallback(
            await finalize(
                rawText: "Clean output",
                candidateText: routingOllama.text,
                modelStopIsComplete: routingOllama.modelStopIsComplete
            ),
            raw: "Clean output"
        )

        // Absent or JSON-null `done` is not `done == false`, so a stop reason is finished.
        let finishedBodies: [(URL, [String: Any])] = [
            (chatEndpoint, ["message": ["role": "assistant", "content": shortened], "done": true, "done_reason": "stop"]),
            (generateEndpoint, ["response": shortened, "done": true, "done_reason": "STOP"]),
            (chatEndpoint, ["message": ["role": "assistant", "content": shortened], "done_reason": "stop"]),
            (generateEndpoint, ["response": shortened, "done_reason": " stop "]),
            (chatEndpoint, ["message": ["role": "assistant", "content": shortened], "done": NSNull(), "done_reason": "Stop"]),
            (generateEndpoint, ["response": shortened, "done": NSNull(), "done_reason": "stop"])
        ]
        for (endpoint, body) in finishedBodies {
            let decoded = try OllamaCorrector.responseText(from: try Self.json(body), endpoint: endpoint)
            XCTAssertEqual(decoded.text, shortened)
            XCTAssertEqual(decoded.stop, .finished, String(describing: body["done_reason"]))
            XCTAssertTrue(decoded.modelStopIsComplete)
            let final = await finalize(
                rawText: rawFive,
                candidateText: decoded.text,
                modelStopIsComplete: decoded.modelStopIsComplete
            )
            XCTAssertEqual(final.text, shortened)
            guard case .accepted = final.validationOutcome else {
                return XCTFail("Finished Ollama stop within the deletion ceiling was \(final.validationOutcome)")
            }
        }

        let paddedStopButNotDone = try OllamaCorrector.responseText(from: try Self.json([
            "message": ["role": "assistant", "content": keptSix],
            "done": false,
            "done_reason": " stop "
        ]), endpoint: chatEndpoint)
        XCTAssertEqual(paddedStopButNotDone.stop, .notFinished)
        XCTAssertFalse(paddedStopButNotDone.modelStopIsComplete)

        for endpoint in [chatEndpoint, generateEndpoint] {
            let lengthWithoutContent = try OllamaCorrector.responseText(
                from: try Self.json(["done": true, "done_reason": "length", "model": "qwen"]),
                endpoint: endpoint
            )
            XCTAssertEqual(lengthWithoutContent.text, "")
            XCTAssertEqual(lengthWithoutContent.stop, .length)
            assertFallback(
                await finalize(
                    rawText: rawTen,
                    candidateText: lengthWithoutContent.text,
                    modelStopIsComplete: lengthWithoutContent.modelStopIsComplete
                ),
                raw: rawTen
            )

            let notDoneWithoutContent = try OllamaCorrector.responseText(
                from: try Self.json(["done": false]),
                endpoint: endpoint
            )
            XCTAssertEqual(notDoneWithoutContent.text, "")
            XCTAssertEqual(notDoneWithoutContent.stop, .notFinished)
            XCTAssertFalse(notDoneWithoutContent.modelStopIsComplete)

            XCTAssertThrowsError(
                try OllamaCorrector.responseText(from: try Self.json(["done": true]), endpoint: endpoint)
            ) { error in
                XCTAssertTrue(error is DecodingError)
            }
            XCTAssertThrowsError(
                try OllamaCorrector.responseText(from: Data("{".utf8), endpoint: endpoint)
            ) { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
    }

    func testRtlNulAndHugeLengthStopFallBackToExactRawTranscript() async throws {
        let raw = "\u{202E}שלום עולם واحد اثنان alpha bravo charlie delta echo foxtrot"
        let cut = "\u{202E}שלום עולם واحد اثنان alpha bravo"
        let ratio = Self.deletionRatio(raw: raw, candidate: cut)
        XCTAssertEqual(ratio, 0.40, accuracy: 0.000_000_1)
        XCTAssertLessThanOrEqual(ratio, CorrectionPolicy.defaultMaxDeletionRatio)

        let openAI = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": cut], "finish_reason": "length"]],
            "system_fingerprint": "rtl"
        ]))
        XCTAssertEqual(openAI.text, cut)
        XCTAssertEqual(openAI.stop, .length)
        let openAIFinal = await finalize(
            rawText: raw,
            candidateText: openAI.text,
            modelStopIsComplete: openAI.modelStopIsComplete
        )
        assertFallback(openAIFinal, raw: raw)
        XCTAssertEqual(openAIFinal.text, raw)
        XCTAssertTrue(openAIFinal.text.hasPrefix("\u{202E}"))

        let combiningRaw = "cafe\u{0301} nai\u{0308}ve alpha bravo charlie delta echo foxtrot golf"
        let combiningCut = "cafe\u{0301} nai\u{0308}ve alpha bravo charlie delta"
        XCTAssertLessThanOrEqual(Self.deletionRatio(raw: combiningRaw, candidate: combiningCut), 0.40)
        let generate = try OllamaCorrector.responseText(from: try Self.json([
            "response": combiningCut,
            "done": true,
            "done_reason": "length"
        ]), endpoint: generateEndpoint)
        XCTAssertEqual(generate.text, combiningCut)
        let generateFinal = await finalize(
            rawText: combiningRaw,
            candidateText: generate.text,
            modelStopIsComplete: generate.modelStopIsComplete
        )
        assertFallback(generateFinal, raw: combiningRaw)
        XCTAssertEqual(generateFinal.text, combiningRaw)

        // U+0000 is not whitespace, so it stays inside the first token.
        let nulRaw = "alpha\u{0000}bravo charlie delta echo"
        let nulCandidate = "alpha\u{0000}bravo charlie delta echo foxtrot"
        let nulAddition = Self.additionRatio(raw: nulRaw, candidate: nulCandidate)
        XCTAssertEqual(nulAddition, 0.25, accuracy: 0.000_000_1)
        XCTAssertFalse(nulAddition > CorrectionPolicy().maxAdditionRatio)
        let nulStop = try OpenAICompatibleCorrector.responseText(
            from: Data(#"{"choices":[{"message":{"content":"alpha\u0000bravo charlie delta echo foxtrot"},"finish_reason":"stop"}]}"#.utf8)
        )
        XCTAssertEqual(nulStop.stop, .finished)
        XCTAssertEqual(nulStop.text, nulCandidate)
        XCTAssertTrue(nulStop.text.contains("\u{0000}"))
        let nulAccepted = await finalize(
            rawText: nulRaw,
            candidateText: nulStop.text,
            modelStopIsComplete: nulStop.modelStopIsComplete
        )
        XCTAssertEqual(nulAccepted.text, nulCandidate)
        guard case .accepted = nulAccepted.validationOutcome else {
            return XCTFail("A finished correction containing NUL within the addition ceiling was \(nulAccepted.validationOutcome)")
        }

        let nulLength = try OllamaCorrector.responseText(
            from: Data(#"{"message":{"role":"assistant","content":"alpha\u0000bravo charlie delta echo"},"done":true,"done_reason":"length"}"#.utf8),
            endpoint: chatEndpoint
        )
        XCTAssertEqual(nulLength.stop, .length)
        XCTAssertTrue(nulLength.text.contains("\u{0000}"))
        XCTAssertFalse(nulLength.modelStopIsComplete)
        let nulFallback = await finalize(
            rawText: nulRaw,
            candidateText: nulLength.text,
            modelStopIsComplete: nulLength.modelStopIsComplete
        )
        assertFallback(nulFallback, raw: nulRaw)
        XCTAssertEqual(nulFallback.text, nulRaw)
        XCTAssertTrue(nulFallback.text.contains("\u{0000}"))

        let huge = String(repeating: "a", count: 900_000)
        let hugePayload = try Self.json([
            "choices": [["message": ["content": huge], "finish_reason": "length"]],
            "usage": ["completion_tokens": 1024]
        ])
        XCTAssertLessThan(hugePayload.count, LocalEndpointSecurity.maximumCorrectionResponseBytes)
        XCTAssertGreaterThan(hugePayload.count, 900_000)
        let hugeDecoded = try OpenAICompatibleCorrector.responseText(from: hugePayload)
        XCTAssertEqual(hugeDecoded.text.count, 900_000)
        XCTAssertEqual(hugeDecoded.stop, .length)
        XCTAssertFalse(hugeDecoded.modelStopIsComplete)
        // Pipeline span extraction is on the raw dictation, not the model body.
        // The length flag must still drop this body before any ratio check.
        let hugeFinal = await finalize(
            rawText: rawTen,
            candidateText: hugeDecoded.text,
            modelStopIsComplete: hugeDecoded.modelStopIsComplete
        )
        assertFallback(hugeFinal, raw: rawTen)
        XCTAssertEqual(hugeFinal.correctionCandidate?.text.count, 900_000)
        XCTAssertNotEqual(hugeFinal.text, huge)
    }

    func testLongPrefixUnderCeilingWithLengthStopReturnsRawNotThePrefix() async throws {
        let words = (1...100).map { "w\($0)" }
        let raw = words.joined(separator: " ")
        let prefix60 = words.prefix(60).joined(separator: " ")
        let prefix59 = words.prefix(59).joined(separator: " ")
        XCTAssertEqual(Self.deletionRatio(raw: raw, candidate: prefix60), 0.40, accuracy: 0.000_000_1)
        XCTAssertEqual(Self.deletionRatio(raw: raw, candidate: prefix59), 0.41, accuracy: 0.000_000_1)
        XCTAssertFalse(Self.deletionRatio(raw: raw, candidate: prefix60) > CorrectionPolicy.defaultMaxDeletionRatio)
        XCTAssertTrue(Self.deletionRatio(raw: raw, candidate: prefix59) > CorrectionPolicy.defaultMaxDeletionRatio)

        let length = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": prefix60], "finish_reason": "length"]]
        ]))
        XCTAssertEqual(length.text, prefix60)
        XCTAssertFalse(length.modelStopIsComplete)
        let lengthFinal = await finalize(
            rawText: raw,
            candidateText: length.text,
            modelStopIsComplete: length.modelStopIsComplete
        )
        assertFallback(lengthFinal, raw: raw)
        XCTAssertEqual(lengthFinal.text, raw)
        XCTAssertNotEqual(lengthFinal.text, prefix60)
        XCTAssertEqual(lengthFinal.correctionCandidate?.text, prefix60)

        let finishedAtCeiling = try OllamaCorrector.responseText(from: try Self.json([
            "response": prefix60,
            "done_reason": "stop"
        ]), endpoint: generateEndpoint)
        XCTAssertEqual(finishedAtCeiling.stop, .finished)
        let accepted = await finalize(
            rawText: raw,
            candidateText: finishedAtCeiling.text,
            modelStopIsComplete: finishedAtCeiling.modelStopIsComplete
        )
        XCTAssertEqual(accepted.text, prefix60)
        guard case .accepted = accepted.validationOutcome else {
            return XCTFail("stop at deletion ratio 0.40 must still be accepted, got \(accepted.validationOutcome)")
        }

        let overCeiling = await finalize(
            rawText: raw,
            candidateText: prefix59,
            modelStopIsComplete: true
        )
        guard case .fallbackToRaw(let reason) = overCeiling.validationOutcome else {
            return XCTFail("stop at deletion ratio 0.41 must hit the old ceiling, got \(overCeiling.validationOutcome)")
        }
        XCTAssertEqual(reason, .correctionUnsupportedEdit)
        XCTAssertEqual(overCeiling.text, raw)
        XCTAssertNotEqual(overCeiling.text, prefix59)

        let lengthOver = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": prefix59], "finish_reason": "length"]]
        ]))
        let lengthOverFinal = await finalize(
            rawText: raw,
            candidateText: lengthOver.text,
            modelStopIsComplete: lengthOver.modelStopIsComplete
        )
        assertFallback(lengthOverFinal, raw: raw)
        XCTAssertEqual(lengthOverFinal.text, raw)
    }

    func testFlagFalseRejectsExactTextBeforeRatiosAndLegacyPayloadStaysComplete() async throws {
        let raw = "alpha bravo charlie delta echo"
        let legacyJSON = Data("""
        {"text":"\(raw)","providerID":"p","modelVersion":"m","edits":[],"latencyMs":0,"promptVersion":"1.0","refusalDetected":false}
        """.utf8)
        let legacy = try JSONDecoder().decode(CorrectionCandidate.self, from: legacyJSON)
        XCTAssertTrue(legacy.modelStopIsComplete)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON) as? [String: Any])
        XCTAssertNil(legacyObject["modelStopIsComplete"])
        let legacyOutcome = CorrectionValidator.validate(
            candidate: legacy,
            raw: Self.rawTranscript(raw),
            policy: CorrectionPolicy(),
            protectedSpans: []
        )
        guard case .accepted = legacyOutcome else {
            return XCTFail("A payload without modelStopIsComplete must validate as complete, got \(legacyOutcome)")
        }
        let legacyFinal = await CorrectionPipeline.execute(
            rawTranscript: Self.rawTranscript(raw),
            corrector: ScriptedCorrector(candidate: legacy),
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .localNetworkOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertEqual(legacyFinal.text, raw)
        guard case .accepted = legacyFinal.validationOutcome else {
            return XCTFail("Legacy candidate was not accepted through the pipeline: \(legacyFinal.validationOutcome)")
        }

        let shortened = "alpha bravo charlie delta"
        let legacyEdit = CorrectionCandidate(
            text: shortened,
            providerID: "p",
            modelVersion: "m"
        )
        XCTAssertTrue(legacyEdit.modelStopIsComplete)
        let legacyEditFinal = await finalize(
            rawText: raw,
            candidateText: legacyEdit.text,
            modelStopIsComplete: legacyEdit.modelStopIsComplete
        )
        XCTAssertEqual(legacyEditFinal.text, shortened)
        guard case .accepted = legacyEditFinal.validationOutcome else {
            return XCTFail("Default-complete short edit must still pass the deletion ceiling")
        }

        let incompleteJSON = try JSONEncoder().encode(CorrectionCandidate(
            text: raw,
            providerID: "p",
            modelVersion: "m",
            modelStopIsComplete: false
        ))
        let incomplete = try JSONDecoder().decode(CorrectionCandidate.self, from: incompleteJSON)
        XCTAssertFalse(incomplete.modelStopIsComplete)
        XCTAssertEqual(incomplete.text, raw)
        let exactButIncomplete = CorrectionValidator.validate(
            candidate: incomplete,
            raw: Self.rawTranscript(raw),
            policy: CorrectionPolicy(),
            protectedSpans: []
        )
        guard case .fallbackToRaw(let exactReason) = exactButIncomplete else {
            return XCTFail("Flag false must fall back even when the text equals the raw text, got \(exactButIncomplete)")
        }
        XCTAssertEqual(exactReason, .correctionUnsupportedEdit)
        let exactFinal = await CorrectionPipeline.execute(
            rawTranscript: Self.rawTranscript(raw),
            corrector: ScriptedCorrector(candidate: incomplete),
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .localNetworkOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        assertFallback(exactFinal, raw: raw)
        XCTAssertEqual(exactFinal.correctionCandidate?.text, raw)

        let expanded = "one two three four five"
        let addition = Self.additionRatio(raw: "one", candidate: expanded)
        XCTAssertGreaterThan(addition, CorrectionPolicy().maxAdditionRatio)
        let flagBeforeRatio = CorrectionValidator.validate(
            candidate: CorrectionCandidate(
                text: expanded,
                providerID: "p",
                modelVersion: "m",
                modelStopIsComplete: false
            ),
            raw: Self.rawTranscript("one"),
            policy: CorrectionPolicy(),
            protectedSpans: []
        )
        guard case .fallbackToRaw(let orderReason) = flagBeforeRatio else {
            return XCTFail("Expected fallback before the addition ceiling, got \(flagBeforeRatio)")
        }
        XCTAssertEqual(orderReason, .correctionUnsupportedEdit)
        XCTAssertNotEqual(orderReason, .correctionHallucination)

        let refusalLooking = CorrectionValidator.validate(
            candidate: CorrectionCandidate(
                text: "As an AI I cannot do that",
                providerID: "p",
                modelVersion: "m",
                modelStopIsComplete: false
            ),
            raw: Self.rawTranscript(raw),
            policy: CorrectionPolicy(),
            protectedSpans: []
        )
        guard case .fallbackToRaw(let refusalOrder) = refusalLooking else {
            return XCTFail("Flag false must win before the refusal check")
        }
        XCTAssertEqual(refusalOrder, .correctionUnsupportedEdit)
    }

    func testLengthStopDoesNotUsePipelineTimeoutAndBudgetsStay1024() async throws {
        let decoded = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": keptSix], "finish_reason": "length"]]
        ]))
        XCTAssertFalse(decoded.modelStopIsComplete)
        let lengthFinal = await finalize(
            rawText: rawTen,
            candidateText: decoded.text,
            modelStopIsComplete: decoded.modelStopIsComplete
        )
        assertFallback(lengthFinal, raw: rawTen)
        XCTAssertEqual(lengthFinal.correctionCandidate?.modelStopIsComplete, false)

        let thrown = await CorrectionPipeline.execute(
            rawTranscript: Self.rawTranscript(rawTen),
            corrector: ThrowingCorrector(),
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .localNetworkOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertEqual(thrown.text, rawTen)
        XCTAssertNil(thrown.correctionCandidate)
        XCTAssertEqual(thrown.validationOutcome, .fallbackToRaw(reason: .correctionTimeout))

        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: rawTen,
            locale: Locale(identifier: "en_US"),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .localNetworkOnly
        )
        let openAIRequest = try OpenAICompatibleCorrector.correctionRequest(
            request,
            endpoint: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
            model: "local-model"
        )
        let openAIBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(openAIRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(openAIBody["max_tokens"] as? Int, 1024)

        let chatRequest = try OllamaCorrector.correctionRequest(
            request,
            endpoint: chatEndpoint,
            model: "qwen"
        )
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(chatRequest.httpBody)) as? [String: Any])
        let chatOptions = try XCTUnwrap(chatBody["options"] as? [String: Any])
        XCTAssertEqual(chatOptions["num_predict"] as? Int, 1024)

        let generateRequest = try OllamaCorrector.correctionRequest(
            request,
            endpoint: generateEndpoint,
            model: "qwen"
        )
        let generateBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(generateRequest.httpBody)) as? [String: Any])
        let generateOptions = try XCTUnwrap(generateBody["options"] as? [String: Any])
        XCTAssertEqual(generateOptions["num_predict"] as? Int, 1024)

        XCTAssertEqual(
            Set(FailureCode.allCases.map(\.rawValue)),
            [
                "noMicrophone",
                "microphonePermissionDenied",
                "accessibilityPermissionDenied",
                "zeroFramesCaptured",
                "captureBackpressure",
                "deviceChangeInterrupted",
                "diskFull",
                "audioEncodingFailed",
                "missingAPIKey",
                "credentialUnavailable",
                "cloudAudioConsentRequired",
                "speechRecognitionPermissionDenied",
                "authFailed",
                "endpointUnreachable",
                "noReadyProvider",
                "modelNotFound",
                "modelDigestMismatch",
                "modelLoadFailed",
                "rateLimited",
                "quotaExhausted",
                "requestTimeout",
                "speechNoSpeech",
                "speechCoverageGap",
                "speechRepeatedLoop",
                "speechProtocolViolation",
                "correctionRefusal",
                "correctionHallucination",
                "correctionProtectedSpanAltered",
                "correctionUnsupportedEdit",
                "correctionTimeout",
                "targetLeaseExpired",
                "targetAppTerminated",
                "secureInputActive",
                "manifestWriteFailed",
                "staleGeneration",
                "buildLacksSpeechAnalyzer",
                "microphoneStalled",
                "captureProtocolViolation",
            ]
        )
    }

    /// `responseText` is a synchronous function. `cancel` must not gain a wait; this does not open a socket.
    func testResponseTextIsSynchronousAndCancelDoesNotWait() async throws {
        let decoded = try OpenAICompatibleCorrector.responseText(from: try Self.json([
            "choices": [["message": ["content": "alpha"], "finish_reason": "stop"]]
        ]))
        XCTAssertEqual(decoded.stop, .finished)

        let openAI = OpenAICompatibleCorrector(
            endpointURL: URL(string: "http://127.0.0.1:9/v1/chat/completions"),
            modelName: "audit"
        )
        let ollama = OllamaCorrector(
            endpointURL: URL(string: "http://127.0.0.1:9/api/chat"),
            modelName: "audit"
        )
        let started = ContinuousClock.now
        await openAI.cancel(sessionID: VoiceSessionID())
        await ollama.cancel(sessionID: VoiceSessionID())
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func rawTranscript(_ text: String) -> RawTranscript {
        RawTranscript(
            text: text,
            localeIdentifier: "en_US",
            providerID: "test.speech",
            modelVersion: "1"
        )
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
        XCTAssertNotNil(
            final.correctionCandidate,
            "Incomplete stop must keep the candidate. A nil candidate is the throw-to-correctionTimeout path.",
            file: file,
            line: line
        )
        XCTAssertNotEqual(
            final.validationOutcome,
            .fallbackToRaw(reason: .correctionTimeout),
            file: file,
            line: line
        )
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

private struct ThrowingCorrector: TranscriptCorrector {
    private struct HostileThrow: Error {}

    let descriptor = CorrectionProviderDescriptor(
        id: "test.throw",
        displayName: "Throw",
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
        throw HostileThrow()
    }

    func cancel(sessionID: VoiceSessionID) async {}
}
