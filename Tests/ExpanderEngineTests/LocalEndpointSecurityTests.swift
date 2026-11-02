import Foundation
import SourceTreeTestSupport
import XCTest
@testable import ExpanderEngine

final class LocalEndpointSecurityTests: XCTestCase {
    override func tearDown() {
        BoundedLocalResponseURLProtocol.resetStops()
        BoundedLocalResponseURLProtocol.resetHits()
        LocalEndpointSecurity.sessionOverride = nil
        VoicePreferences.resetAllForTesting()
        super.tearDown()
    }

    func testStrictValidatorAcceptsOnlyExactLoopbackHTTPHostsAndPreservesEndpointShape() throws {
        let accepted = [
            "http://localhost:11434/v1/chat/completions",
            "https://LOCALHOST:8443/custom/path?mode=fast",
            "http://127.0.0.1:8080/inference",
            "http://[::1]:8080/api/inference",
        ]

        for raw in accepted {
            let endpoint = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(
                try LocalEndpointSecurity.validated(endpoint).absoluteString,
                endpoint.absoluteString,
                "A valid loopback endpoint must retain its scheme, host, port, path, and query: \(raw)"
            )
        }
    }

    func testStrictValidatorRejectsRemoteAndAmbiguousAuthorities() throws {
        let rejected = [
            "https://example.com/v1/chat/completions",
            "http://192.168.1.10:11434/api/generate",
            "http://8.8.8.8/inference",
            "http://[2001:4860:4860::8888]/inference",
            "http://localhost.example.com/inference",
            "http://localhost./inference",
            "http://127.0.0.2/inference",
            "http://2130706433/inference",
            "http://localhost@evil.example/inference",
            "file://localhost/tmp/transcript",
            "ftp://127.0.0.1/inference",
        ]

        for raw in rejected {
            let endpoint = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(
                try LocalEndpointSecurity.validated(endpoint),
                "A local-only route accepted \(raw)"
            )
        }
    }

    func testLocalTransportRefusesRedirectsInsteadOfFollowingTheProposedRequest() throws {
        let delegate = LocalEndpointURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/inference")))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/inference")),
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://example.com/collect"]
            )
        )
        let proposals = [
            "https://example.com/collect",
            "http://127.0.0.1/exact",
            "http://localhost/exact",
            "http://[::1]/exact",
        ]
        let completion = expectation(description: "redirect decision")
        completion.expectedFulfillmentCount = proposals.count

        for raw in proposals {
            let proposed = URLRequest(url: try XCTUnwrap(URL(string: raw)))
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: proposed
            ) { replacement in
                XCTAssertNil(
                    replacement,
                    "A local-only session must never follow a redirect, including \(raw)."
                )
                completion.fulfill()
            }
        }

        wait(for: [completion], timeout: 1)
    }

    func testLocalTransportDoesNotInheritProxyCookiesOrCredentialStorage() {
        let configuration = LocalEndpointSecurity.makeSessionConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
    }

    func testBoundedTransportAcceptsAResponseAtTheExactLimit() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/exact")))

        let (data, response) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: 8,
            using: session
        )

        XCTAssertEqual(data, Data(repeating: 0x41, count: 8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testBoundedTransportRejectsLimitPlusOneAndDeclaredOversizeResponses() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }

        for path in ["limit-plus-one", "declared-oversize"] {
            let request = URLRequest(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1/\(path)"))
            )
            do {
                _ = try await LocalEndpointSecurity.data(
                    for: request,
                    maximumResponseBytes: 8,
                    using: session
                )
                XCTFail("Expected \(path) to be rejected")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .responseTooLarge)
            }
        }
    }

    func testBoundedTransportEnforcesLimitWhenContentLengthIsMissingOrLies() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }

        for path in ["missing-length", "lying-length"] {
            let request = URLRequest(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1/\(path)"))
            )
            do {
                _ = try await LocalEndpointSecurity.data(
                    for: request,
                    maximumResponseBytes: 8,
                    using: session
                )
                XCTFail("Expected \(path) to be rejected")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .responseTooLarge)
            }
        }
    }

    func testBoundedTransportPreservesTaskCancellation() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/hanging")))
        let task = Task {
            try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled local response read must not complete successfully")
        } catch is CancellationError {
            // Expected: callers use structured cancellation to invalidate stale voice work.
        } catch {
            XCTFail("Cancellation was rewritten as \(error)")
        }
    }

    func testBoundedTransportRevalidatesTheResponseURLBeforeReadingItsBody() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/remote-response"))
        )

        do {
            _ = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A response attributed to a remote URL must be refused")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .nonLoopbackHost)
        }
    }

    func testEmptyBodyReturnsEmptyData() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/empty")))

        let (data, response) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: 8,
            using: session
        )

        XCTAssertEqual(data, Data())
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testChunkedBodyAtTheExactLimitSucceeds() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/chunked-exact")))

        let (data, _) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: 8,
            using: session
        )

        XCTAssertEqual(data, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testChunkedBodyOneByteOverTheCapCancels() async throws {
        BoundedLocalResponseURLProtocol.resetStops()
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/chunked-over")))

        do {
            _ = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A body split across chunks must still stop at the cap")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .responseTooLarge)
        }

        let clock = ContinuousClock()
        let started = clock.now
        while !BoundedLocalResponseURLProtocol.didStop("/chunked-over") {
            if clock.now - started > .seconds(1) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            BoundedLocalResponseURLProtocol.didStop("/chunked-over"),
            "Crossing the cap must cancel the task, not keep the extra chunk"
        )
    }

    func testInvalidResponseLimitAndMissingURLAreRejectedBeforeTransport() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1/exact"))

        for limit in [0, -1] {
            do {
                _ = try await LocalEndpointSecurity.data(
                    for: URLRequest(url: url),
                    maximumResponseBytes: limit,
                    using: session
                )
                XCTFail("A non-positive limit must be rejected")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .invalidResponseLimit)
            }
        }

        var missing = URLRequest(url: url)
        missing.url = nil
        do {
            _ = try await LocalEndpointSecurity.data(
                for: missing,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A request without a URL must be rejected")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .missingURL)
        }
    }

    func testDelegateBearingSessionEnforcesTheCap() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }

        let exact = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/exact")))
        let (data, _) = try await LocalEndpointSecurity.data(
            for: exact,
            maximumResponseBytes: 8,
            using: session
        )
        XCTAssertEqual(data, Data(repeating: 0x41, count: 8))

        let over = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/limit-plus-one")))
        do {
            _ = try await LocalEndpointSecurity.data(
                for: over,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("The production delegate must reject limit + 1")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .responseTooLarge)
        }
    }

    func testProductionReadDoesNotAwaitEachByte() throws {
        let source = try SourceTree.text("Sources/ExpanderEngine/Voice/LocalEndpointSecurity.swift")
        let internalBody = try SourceTree.functionBody("using session: URLSession", in: source)
        let publicBody = try SourceTree.functionBody("public static func data(", in: source)
        for body in [source, internalBody, publicBody] {
            XCTAssertFalse(
                body.contains("for try await byte"),
                "The bounded read must await one buffer at a time, not one byte"
            )
            XCTAssertFalse(
                body.contains("session.data(for:"),
                "The bounded read must not buffer a whole body with session.data(for:)"
            )
        }
        XCTAssertEqual(LocalEndpointSecurity.maximumTranscriptionResponseBytes, 4_194_304)
        XCTAssertEqual(LocalEndpointSecurity.maximumTranscriptionResponseBytes, 4 * 1024 * 1024)

        let tests = try SourceTree.text("Tests/ExpanderEngineTests/LocalEndpointSecurityTests.swift")
        let byteLoop = try SourceTree.functionBody("private func read" + "OneByteAtATime(", in: tests)
        XCTAssertTrue(byteLoop.contains("for try await byte"))
        XCTAssertTrue(byteLoop.contains("bytes(for:"))
    }

    /// Min of 10 interleaved runs. The byte arm is the old per-byte loop, kept only here.
    /// Payload is 1 MiB. Final run on 2026-11-02: byteMinMs=26.086, bufferMinMs=0.185,
    /// byteSpreadMs=1.997, bufferSpreadMs=0.166. The gap is larger than either spread.
    func testBoundedReadIsNotSlowerThanTheOneByteLoop() async throws {
        let payload = BoundedLocalResponseURLProtocol.benchmarkPayload
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLocalResponseURLProtocol.self]
        let byteSession = URLSession(configuration: configuration)
        let bufferSession = makeDelegateBearingSession()
        defer {
            byteSession.invalidateAndCancel()
            bufferSession.invalidateAndCancel()
        }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/benchmark")))
        let limit = payload.count

        let warmedByte = try await readOneByteAtATime(
            request,
            maximumResponseBytes: limit,
            session: byteSession
        )
        let (warmedBuffer, _) = try await LocalEndpointSecurity.data(
            for: request,
            maximumResponseBytes: limit,
            using: bufferSession
        )
        XCTAssertEqual(warmedByte, payload)
        XCTAssertEqual(warmedBuffer, payload)

        let rounds = 10
        var byteSamples: [Duration] = []
        var bufferSamples: [Duration] = []
        byteSamples.reserveCapacity(rounds)
        bufferSamples.reserveCapacity(rounds)
        let clock = ContinuousClock()

        for index in 0..<rounds {
            let measureByte = {
                try await self.timed(clock) {
                    try await self.readOneByteAtATime(
                        request,
                        maximumResponseBytes: limit,
                        session: byteSession
                    )
                }
            }
            let measureBuffer = {
                try await self.timed(clock) {
                    let (data, _) = try await LocalEndpointSecurity.data(
                        for: request,
                        maximumResponseBytes: limit,
                        using: bufferSession
                    )
                    return data
                }
            }
            if index.isMultiple(of: 2) {
                byteSamples.append(try await measureByte())
                bufferSamples.append(try await measureBuffer())
            } else {
                bufferSamples.append(try await measureBuffer())
                byteSamples.append(try await measureByte())
            }
        }

        let byteMs = byteSamples.map(Self.milliseconds)
        let bufferMs = bufferSamples.map(Self.milliseconds)
        let byteMin = try XCTUnwrap(byteMs.min())
        let bufferMin = try XCTUnwrap(bufferMs.min())
        let byteSpread = (byteMs.max() ?? byteMin) - byteMin
        let bufferSpread = (bufferMs.max() ?? bufferMin) - bufferMin
        print(String(
            format: "endpoint-chunk-bench n=%d payload=%d byteMinMs=%.3f bufferMinMs=%.3f byteSpreadMs=%.3f bufferSpreadMs=%.3f",
            rounds,
            payload.count,
            byteMin,
            bufferMin,
            byteSpread,
            bufferSpread
        ))
        XCTAssertLessThanOrEqual(
            bufferMin,
            byteMin * 1.05,
            String(
                format: "buffer min %.3f ms was more than 5%% slower than the byte-loop min %.3f ms (spreads %.3f / %.3f)",
                bufferMin,
                byteMin,
                bufferSpread,
                byteSpread
            )
        )
    }

    func testConcurrentSharedDelegateReadsDoNotMixBodies() async throws {
        let pairsPerWave = 8
        let waves = 8
        for wave in 0..<waves {
            let results = try await concurrentWave(wave, pairs: pairsPerWave)
            XCTAssertEqual(results.count, pairsPerWave)
            for result in results {
                XCTAssertEqual(
                    result.left,
                    Data(repeating: 0x11, count: 8),
                    "Delegate-less read \(result.id) mixed or truncated"
                )
                XCTAssertEqual(
                    result.right,
                    Data(repeating: 0x22, count: 8),
                    "Delegate-bearing read \(result.id) mixed or truncated"
                )
            }
        }
    }

    func testTransportCancellationStaysURLErrorWhenTheTaskIsNotCancelled() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/transport-cancelled")))

        do {
            _ = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("A cancelled transport must not return a body")
        } catch is CancellationError {
            XCTFail("URLError.cancelled was rewritten to CancellationError without Task.cancel")
        } catch {
            assertURLError(error, code: .cancelled)
        }
    }

    func testPartialBodyThenTransportErrorDoesNotReturnSuccess() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/partial-then-lost")))

        do {
            let (data, _) = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTFail("Partial body \(data as NSData) was returned as success after the transport failed")
        } catch is CancellationError {
            XCTFail("A dropped connection was rewritten as cancellation")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTFail("A dropped connection was rewritten as \(violation)")
        } catch {
            assertURLError(error, code: .networkConnectionLost)
        }
    }

    func testCancellationAfterTheFirstStaggeredChunk() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/stagger-cancel")))
        let task = Task {
            try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            let (data, _) = try await task.value
            XCTFail("Cancel after the first chunk returned \(data as NSData)")
        } catch is CancellationError {
            // The staggered tail would have completed under the cap. Cancellation wins.
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTFail("Cancel after the first chunk was rewritten as \(violation)")
        } catch {
            XCTFail("Cancel after the first chunk was rewritten as \(error)")
        }
    }

    func testStaggeredOverCapStaysResponseTooLargeAcrossRepeats() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }

        for iteration in 0..<20 {
            let path = "/chunked-over-repeat/\(iteration)"
            BoundedLocalResponseURLProtocol.resetStops()
            let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1\(path)")))
            do {
                let (data, _) = try await LocalEndpointSecurity.data(
                    for: request,
                    maximumResponseBytes: 8,
                    using: session
                )
                XCTFail("Iteration \(iteration) returned \(data as NSData) instead of responseTooLarge")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, .responseTooLarge, "Iteration \(iteration)")
            } catch {
                XCTFail("Iteration \(iteration) threw \(error) instead of responseTooLarge")
            }

            let clock = ContinuousClock()
            let started = clock.now
            while !BoundedLocalResponseURLProtocol.didStop(path) {
                if clock.now - started > .seconds(1) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(
                BoundedLocalResponseURLProtocol.didStop(path),
                "Iteration \(iteration) did not cancel the task after the extra chunk"
            )
        }
    }

    func testOneByteChunksAtTheCapPreserveOrder() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let exact = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/one-byte-exact")))
        let (data, _) = try await LocalEndpointSecurity.data(
            for: exact,
            maximumResponseBytes: 64,
            using: session
        )
        XCTAssertEqual(data, Data((0..<64).map { UInt8($0) }))

        try await assertViolation(
            .responseTooLarge,
            request: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/one-byte-over"))),
            limit: 64,
            session: session
        )
    }

    func testCapOfOneAcceptsOneByteAndRefusesTwo() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }

        let (data, _) = try await LocalEndpointSecurity.data(
            for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/cap-one"))),
            maximumResponseBytes: 1,
            using: session
        )
        XCTAssertEqual(data, Data([0x7E]))

        try await assertViolation(
            .responseTooLarge,
            request: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/cap-two"))),
            limit: 1,
            session: session
        )
    }

    func testEmptyChunkDoesNotCountTowardTheCap() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let (data, _) = try await LocalEndpointSecurity.data(
            for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/empty-middle"))),
            maximumResponseBytes: 8,
            using: session
        )
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testContentLengthUnderTheCapDoesNotAllowALaterChunkToCross() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        try await assertViolation(
            .responseTooLarge,
            request: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/length-under-then-over"))),
            limit: 8,
            session: session
        )
    }

    func testMissingContentLengthAtTheExactCapSucceeds() async throws {
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await LocalEndpointSecurity.data(
            for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/missing-length-exact"))),
            maximumResponseBytes: 8,
            using: session
        )
        XCTAssertEqual(data, Data(repeating: 0x43, count: 8))
        XCTAssertEqual(response.expectedContentLength, -1)
    }

    func testResponseURLMatchesValidatedLoopbackPolicy() async throws {
        let rejected: [(String, LocalEndpointSecurity.Violation)] = [
            ("http://user:secret@127.0.0.1/userinfo", .credentialsNotAllowed),
            ("http://127.0.0.1@evil.example/inference", .credentialsNotAllowed),
            ("http://localhost./inference", .nonLoopbackHost),
            ("http://127.0.0.1./inference", .nonLoopbackHost),
            ("http://127.0.0.1.evil/inference", .nonLoopbackHost),
        ]
        let session = makeBoundedTransportSession()
        defer { session.invalidateAndCancel() }

        for (raw, expected) in rejected {
            let spoofed = try XCTUnwrap(URL(string: raw))
            do {
                _ = try LocalEndpointSecurity.validated(spoofed)
                XCTFail("validated() accepted \(raw)")
            } catch let violation as LocalEndpointSecurity.Violation {
                XCTAssertEqual(violation, expected, raw)
            }

            var components = try XCTUnwrap(URLComponents(string: "http://127.0.0.1/spoof-response"))
            components.queryItems = [URLQueryItem(name: "response", value: raw)]
            let request = URLRequest(url: try XCTUnwrap(components.url))
            try await assertViolation(expected, request: request, limit: 8, session: session)
        }

        let accepted = [
            "http://localhost/spoof-localhost",
            "http://[::1]/spoof-ipv6",
        ]
        for raw in accepted {
            let spoofed = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(
                try LocalEndpointSecurity.validated(spoofed).absoluteString,
                spoofed.absoluteString
            )
            var components = try XCTUnwrap(URLComponents(string: "http://127.0.0.1/spoof-response"))
            components.queryItems = [URLQueryItem(name: "response", value: raw)]
            let (data, response) = try await LocalEndpointSecurity.data(
                for: URLRequest(url: try XCTUnwrap(components.url)),
                maximumResponseBytes: 8,
                using: session
            )
            XCTAssertEqual(data, Data(repeating: 0x11, count: 8), raw)
            XCTAssertEqual(response.url?.absoluteString, spoofed.absoluteString, raw)
        }
    }

    func testPercentEncodedPathStillEnforcesTheCap() async throws {
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let paths = [
            "http://127.0.0.1/bounded-cap/caf%C3%A9",
            "http://127.0.0.1/bounded-cap/%6Fversize",
        ]
        for raw in paths {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(try LocalEndpointSecurity.validated(url).absoluteString, url.absoluteString)
            try await assertViolation(
                .responseTooLarge,
                request: URLRequest(url: url),
                limit: 8,
                session: session
            )
        }
    }

    func testSequentialDelegateLessSessionsEachReturnTheirFullBody() async throws {
        let first = makeBoundedTransportSession()
        defer { first.invalidateAndCancel() }
        let (firstBody, _) = try await LocalEndpointSecurity.data(
            for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/concurrent/seq-a/left"))),
            maximumResponseBytes: 8,
            using: first
        )

        let second = makeBoundedTransportSession()
        defer { second.invalidateAndCancel() }
        let (secondBody, _) = try await LocalEndpointSecurity.data(
            for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/concurrent/seq-b/right"))),
            maximumResponseBytes: 8,
            using: second
        )

        XCTAssertEqual(firstBody, Data(repeating: 0x11, count: 8))
        XCTAssertEqual(secondBody, Data(repeating: 0x22, count: 8))
    }

    func testRefusedLoopbackRedirectDoesNotReturnTheFollowedBody() async throws {
        BoundedLocalResponseURLProtocol.resetHits()
        let session = makeDelegateBearingSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/redirect-loopback")))

        do {
            let (data, response) = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: 8,
                using: session
            )
            XCTAssertNotEqual(data, Data(repeating: 0x41, count: 8))
            XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } catch is CancellationError {
            XCTFail("Refusing a loopback redirect must not cancel the caller")
        } catch {
            // A refused redirect may surface as a transport error. It must not be the followed body.
        }

        XCTAssertEqual(
            BoundedLocalResponseURLProtocol.hitCount(for: "/redirect-loopback"),
            1
        )
        XCTAssertEqual(
            BoundedLocalResponseURLProtocol.hitCount(for: "/exact"),
            0,
            "The session followed a loopback redirect to /exact"
        )
    }

    func testSessionOverrideEnforcesTheCapAndClears() async throws {
        let session = makeBoundedTransportSession()
        defer {
            LocalEndpointSecurity.sessionOverride = nil
            session.invalidateAndCancel()
        }
        LocalEndpointSecurity.sessionOverride = session

        let (data, _) = try await LocalEndpointSecurity.data(
            for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/exact"))),
            maximumResponseBytes: 8
        )
        XCTAssertEqual(data, Data(repeating: 0x41, count: 8))

        do {
            _ = try await LocalEndpointSecurity.data(
                for: URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/limit-plus-one"))),
                maximumResponseBytes: 8
            )
            XCTFail("sessionOverride accepted a body past the cap")
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, .responseTooLarge)
        }
        XCTAssertTrue(LocalEndpointSecurity.sessionOverride === session)
    }

    func testPreferencesRejectRemoteWritesAndHealStaleRemoteDefaults() throws {
        let local = try XCTUnwrap(URL(string: "http://localhost:1234/v1/chat/completions"))
        let remote = try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))

        XCTAssertTrue(VoicePreferences.setLocalLLMEndpoint(local))
        XCTAssertFalse(VoicePreferences.setLocalLLMEndpoint(remote))
        XCTAssertEqual(VoicePreferences.localLLMEndpoint, local)

        UserDefaults.standard.set(remote.absoluteString, forKey: VoicePreferences.localLLMEndpointKey)
        XCTAssertEqual(VoicePreferences.localLLMEndpoint, VoicePreferences.defaultLocalLLMEndpoint)
        XCTAssertNil(UserDefaults.standard.string(forKey: VoicePreferences.localLLMEndpointKey))

        UserDefaults.standard.set(remote.absoluteString, forKey: VoicePreferences.whisperEndpointKey)
        XCTAssertEqual(VoicePreferences.whisperEndpoint, VoicePreferences.defaultWhisperEndpoint)
        XCTAssertNil(UserDefaults.standard.string(forKey: VoicePreferences.whisperEndpointKey))
    }

    func testEveryLocalProviderRefusesRemoteEndpointBeforeReadinessOrContentEgress() async throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/collect"))
        let correctors: [any TranscriptCorrector] = [
            OllamaCorrector(endpointURL: remote),
            OpenAICompatibleCorrector(endpointURL: remote),
        ]

        for corrector in correctors {
            let readiness = await corrector.probe()
            XCTAssertEqual(readiness, .requiresConfiguration(.invalidEndpointFormat))
            do {
                _ = try await corrector.correct(
                    VoiceFixtures.correctionRequest("private dictated transcript", privacyRoute: .localNetworkOnly)
                )
                XCTFail("\(corrector.descriptor.id) sent content to a non-loopback endpoint")
            } catch let failure as VoiceFailure {
                XCTAssertEqual(failure.code, .endpointUnreachable)
                XCTAssertEqual(failure.userAction, .configureEndpoint)
            } catch {
                XCTFail("Expected a structured local-endpoint refusal, got \(error)")
            }
        }

        let whisperReachable = await WhisperServerSetup.isReachable(endpoint: remote, timeout: 30)
        XCTAssertFalse(whisperReachable)
        let models = await LocalLLMModelCatalog.shared.fetchAvailableLocalModels(endpoint: remote)
        XCTAssertEqual(models, [])

        let serverStart = await WhisperServerController.shared.start(endpoint: remote)
        guard case .failure(.invalidEndpoint) = serverStart else {
            return XCTFail("A remote endpoint reached Whisper server startup: \(serverStart)")
        }
    }

    private func assertViolation(
        _ expected: LocalEndpointSecurity.Violation,
        request: URLRequest,
        limit: Int,
        session: URLSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let (data, _) = try await LocalEndpointSecurity.data(
                for: request,
                maximumResponseBytes: limit,
                using: session
            )
            XCTFail(
                "Expected \(expected) but received \(data.count) bytes",
                file: file,
                line: line
            )
        } catch let violation as LocalEndpointSecurity.Violation {
            XCTAssertEqual(violation, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected) but threw \(error)", file: file, line: line)
        }
    }

    private func assertURLError(
        _ error: Error,
        code: URLError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let urlError = error as? URLError {
            XCTAssertEqual(urlError.code, code, file: file, line: line)
            return
        }
        let bridged = error as NSError
        XCTAssertEqual(bridged.domain, NSURLErrorDomain, "\(error)", file: file, line: line)
        XCTAssertEqual(bridged.code, code.rawValue, file: file, line: line)
    }

    private func concurrentWave(
        _ wave: Int,
        pairs: Int
    ) async throws -> [(id: Int, left: Data, right: Data)] {
        let sessions: [(URLSession, URLSession)] = (0..<pairs).map { _ in
            (makeBoundedTransportSession(), makeDelegateBearingSession())
        }
        defer {
            for pair in sessions {
                pair.0.invalidateAndCancel()
                pair.1.invalidateAndCancel()
            }
        }

        return try await withThrowingTaskGroup(
            of: (id: Int, left: Data, right: Data).self
        ) { group in
            for (index, pair) in sessions.enumerated() {
                let id = wave * pairs + index
                let leftSession = pair.0
                let rightSession = pair.1
                group.addTask {
                    let leftURL = try XCTUnwrap(URL(string: "http://127.0.0.1/concurrent/\(id)/left"))
                    let rightURL = try XCTUnwrap(URL(string: "http://127.0.0.1/concurrent/\(id)/right"))
                    async let left = LocalEndpointSecurity.data(
                        for: URLRequest(url: leftURL),
                        maximumResponseBytes: 8,
                        using: leftSession
                    )
                    async let right = LocalEndpointSecurity.data(
                        for: URLRequest(url: rightURL),
                        maximumResponseBytes: 8,
                        using: rightSession
                    )
                    let (leftResult, rightResult) = try await (left, right)
                    return (id, leftResult.0, rightResult.0)
                }
            }

            var results: [(id: Int, left: Data, right: Data)] = []
            results.reserveCapacity(pairs)
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func makeBoundedTransportSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLocalResponseURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Same protocol stack as the injected session, but with the production data delegate so the
    /// benchmark and the cap tests exercise the session shape `LocalEndpointSecurity.session` uses.
    private func makeDelegateBearingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLocalResponseURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: LocalEndpointURLSessionDelegate.shared,
            delegateQueue: nil
        )
    }

    /// The pre-change read. Production must not keep this loop; the benchmark compares against it.
    private func readOneByteAtATime(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        session: URLSession
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            bytes.task.cancel()
            throw LocalEndpointSecurity.Violation.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 16 * 1024))
        for try await byte in bytes {
            if Task.isCancelled {
                bytes.task.cancel()
                throw CancellationError()
            }
            guard data.count < maximumResponseBytes else {
                bytes.task.cancel()
                throw LocalEndpointSecurity.Violation.responseTooLarge
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private func timed(
        _ clock: ContinuousClock,
        _ body: () async throws -> Data
    ) async throws -> Duration {
        let start = clock.now
        let data = try await body()
        let elapsed = clock.now - start
        XCTAssertEqual(data.count, BoundedLocalResponseURLProtocol.benchmarkPayload.count)
        return elapsed
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

private final class BoundedLocalResponseURLProtocol: URLProtocol, @unchecked Sendable {
    static let benchmarkPayload = Data(repeating: 0x5A, count: 1024 * 1024)

    private static let stopLock = NSLock()
    private static var stoppedPaths = Set<String>()
    private static var hitPaths: [String] = []

    static func resetStops() {
        stopLock.lock()
        stoppedPaths.removeAll()
        stopLock.unlock()
    }

    static func resetHits() {
        stopLock.lock()
        hitPaths.removeAll()
        stopLock.unlock()
    }

    static func didStop(_ path: String) -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stoppedPaths.contains(path)
    }

    static func hitCount(for path: String) -> Int {
        stopLock.lock()
        defer { stopLock.unlock() }
        return hitPaths.reduce(into: 0) { count, hit in
            if hit == path { count += 1 }
        }
    }

    private static func recordHit(_ path: String) {
        stopLock.lock()
        hitPaths.append(path)
        stopLock.unlock()
    }

    /// `/concurrent/<id>/left` is 0x11 and `/concurrent/<id>/right` is 0x22.
    /// Distinct paths keep each in-flight body on its own protocol instance.
    private static func concurrentByte(for path: String) -> UInt8? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "concurrent" else { return nil }
        switch parts[2] {
        case "left": return 0x11
        case "right": return 0x22
        default: return nil
        }
    }

    private let gate = NSLock()
    private var closed = false
    private var tailWork: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.recordHit(requestURL.path)

        if let byte = Self.concurrentByte(for: requestURL.path) {
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data(repeating: byte, count: 8)],
                staggerTail: false
            )
            return
        }
        if requestURL.path == "/spoof-response" {
            let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
            let raw = components?.queryItems?.first(where: { $0.name == "response" })?.value
            guard let raw, let responseURL = URL(string: raw) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            deliver(
                responseURL: responseURL,
                headers: ["Content-Length": "8"],
                chunks: [Data(repeating: 0x11, count: 8)],
                staggerTail: false
            )
            return
        }
        if requestURL.path.hasPrefix("/bounded-cap") {
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x60, count: 9)],
                staggerTail: false
            )
            return
        }
        if requestURL.path.hasPrefix("/chunked-over-repeat/") {
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x47, count: 4), Data(repeating: 0x47, count: 5)],
                staggerTail: true
            )
            return
        }
        if requestURL.path == "/one-byte-exact" || requestURL.path == "/one-byte-over" {
            let count = requestURL.path.hasSuffix("over") ? 65 : 64
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: (0..<count).map { Data([UInt8($0 & 0xFF)]) },
                staggerTail: false
            )
            return
        }

        switch requestURL.path {
        case "/exact":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data(repeating: 0x41, count: 8)],
                staggerTail: false
            )
        case "/limit-plus-one":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x42, count: 9)],
                staggerTail: false
            )
        case "/declared-oversize":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "9"],
                chunks: [],
                staggerTail: false
            )
        case "/missing-length":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x43, count: 9)],
                staggerTail: false
            )
        case "/lying-length":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "1"],
                chunks: [Data(repeating: 0x44, count: 9)],
                staggerTail: false
            )
        case "/hanging":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x45, count: 1)],
                staggerTail: false,
                finish: false
            )
        case "/remote-response":
            deliver(
                responseURL: URL(string: "https://example.invalid/collect")!,
                headers: nil,
                chunks: [Data(repeating: 0x46, count: 1)],
                staggerTail: false
            )
        case "/empty":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "0"],
                chunks: [],
                staggerTail: false
            )
        case "/chunked-exact":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data([1, 2, 3]), Data([4, 5, 6, 7, 8])],
                staggerTail: true
            )
        case "/chunked-over":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x47, count: 4), Data(repeating: 0x47, count: 5)],
                staggerTail: true
            )
        case "/benchmark":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": String(Self.benchmarkPayload.count)],
                chunks: [Self.benchmarkPayload],
                staggerTail: false
            )
        case "/transport-cancelled":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x52, count: 4)],
                staggerTail: false,
                finish: false,
                failure: URLError(.cancelled)
            )
        case "/partial-then-lost":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x51, count: 4)],
                staggerTail: false,
                finish: false,
                failure: URLError(.networkConnectionLost)
            )
        case "/stagger-cancel":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data(repeating: 0x53, count: 4), Data(repeating: 0x54, count: 4)],
                staggerTail: true,
                staggerMilliseconds: 5_000
            )
        case "/cap-one":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "1"],
                chunks: [Data([0x7E])],
                staggerTail: false
            )
        case "/cap-two":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data([0x7E, 0x7F])],
                staggerTail: false
            )
        case "/empty-middle":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "8"],
                chunks: [Data([1, 2, 3, 4]), Data(), Data([5, 6, 7, 8])],
                staggerTail: false
            )
        case "/length-under-then-over":
            deliver(
                responseURL: requestURL,
                headers: ["Content-Length": "4"],
                chunks: [Data(repeating: 0x10, count: 4), Data(repeating: 0x11, count: 5)],
                staggerTail: true
            )
        case "/missing-length-exact":
            deliver(
                responseURL: requestURL,
                headers: nil,
                chunks: [Data(repeating: 0x43, count: 8)],
                staggerTail: false
            )
        case "/redirect-loopback":
            redirectWithoutFollowing(requestURL)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {
        cancelTail()
        if let path = request.url?.path {
            Self.stopLock.lock()
            Self.stoppedPaths.insert(path)
            Self.stopLock.unlock()
        }
        guard markClosed() else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    /// `wasRedirectedTo` runs the session delegate inline. Leaving the protocol load stack
    /// avoids a deadlock when that delegate refuses, then delivers the original 307 only if
    /// the refusal did not already stop this load. Following would hit `/exact`.
    private func redirectWithoutFollowing(_ requestURL: URL) {
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://127.0.0.1/exact"]
        )!
        let redirected = URLRequest(url: URL(string: "http://127.0.0.1/exact")!)
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            guard self.markClosed() else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("redir".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func deliver(
        responseURL: URL,
        headers: [String: String]?,
        chunks: [Data],
        staggerTail: Bool,
        finish: Bool = true,
        failure: URLError? = nil,
        staggerMilliseconds: Int = 30
    ) {
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let client = self.client
        let send: (Data) -> Void = { chunk in
            client?.urlProtocol(self, didLoad: chunk)
        }
        let closeOut = {
            if let failure {
                self.failIfOpen(failure)
            } else if finish {
                self.finishIfOpen()
            }
        }
        if !staggerTail || chunks.count < 2 {
            for chunk in chunks {
                send(chunk)
            }
            closeOut()
            return
        }
        send(chunks[0])
        let tail = Array(chunks.dropFirst())
        let work = DispatchWorkItem {
            guard !self.isClosed() else { return }
            for chunk in tail {
                if self.isClosed() { return }
                send(chunk)
            }
            closeOut()
        }
        storeTail(work)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(staggerMilliseconds),
            execute: work
        )
    }

    private func finishIfOpen() {
        guard markClosed() else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func failIfOpen(_ error: Error) {
        guard markClosed() else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func isClosed() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return closed
    }

    private func storeTail(_ work: DispatchWorkItem) {
        gate.lock()
        tailWork = work
        gate.unlock()
    }

    private func cancelTail() {
        gate.lock()
        let work = tailWork
        gate.unlock()
        work?.cancel()
    }

    private func markClosed() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        if closed { return false }
        closed = true
        return true
    }
}
