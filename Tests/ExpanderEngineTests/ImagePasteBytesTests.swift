import AppKit
import XCTest
@testable import ExpanderEngine

/// Native image paste must publish the stored file bytes. Re-encoding through
/// `NSImage` flattens animated GIF and replaces PNG/JPEG/TIFF with a new TIFF+PNG pair.
final class ImagePasteBytesTests: XCTestCase {
    private let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private let gifType = NSPasteboard.PasteboardType("public.gif")

    private func oneByOneImage() throws -> NSImage {
        let pixels = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ))
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(pixels)
        return image
    }

    private func repoSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func assertFallback(
        _ result: PasteboardBroker.ExpansionImageRepresentations,
        image: NSImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = PasteboardBroker().expansionImageRepresentations(image: image, imagePath: nil)
        XCTAssertEqual(result.items.map(\.0), [.tiff, .png], file: file, line: line)
        XCTAssertEqual(result.items.count, 2, file: file, line: line)
        XCTAssertFalse(result.items.isEmpty, file: file, line: line)
        XCTAssertGreaterThan(result.items[0].1.count, 0, file: file, line: line)
        XCTAssertGreaterThan(result.items[1].1.count, 0, file: file, line: line)
        XCTAssertEqual(result.payloadBytes, result.items[0].1.count + result.items[1].1.count, file: file, line: line)
        XCTAssertEqual(result.payloadBytes, expected.payloadBytes, file: file, line: line)
        XCTAssertEqual(result.items[0].1, expected.items[0].1, file: file, line: line)
        XCTAssertEqual(result.items[1].1, expected.items[1].1, file: file, line: line)
    }

    private func assertNative(
        _ result: PasteboardBroker.ExpansionImageRepresentations,
        type: NSPasteboard.PasteboardType,
        bytes: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.items.count, 1, file: file, line: line)
        XCTAssertEqual(result.items.first?.0, type, file: file, line: line)
        XCTAssertEqual(result.items.first?.1, bytes, file: file, line: line)
        XCTAssertEqual(result.payloadBytes, bytes.count, file: file, line: line)
        XCTAssertFalse(result.items.contains { $0.0 == .tiff && type != .tiff }, file: file, line: line)
        XCTAssertFalse(result.items.contains { $0.0 == .png && type != .png }, file: file, line: line)
    }

    func testStoredPNGPublishesPNGBytesOnlyAndPayloadMatchesFileSize() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        let bytes = Data("not-a-reencoded-png-\(UUID().uuidString)".utf8)
        var reads = 0
        let result = broker.expansionImageRepresentations(
            image: image,
            imagePath: "Stored.PNG",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 10))
            },
            read: { _ in
                reads += 1
                return bytes
            }
        )
        XCTAssertEqual(reads, 1)
        assertNative(result, type: .png, bytes: bytes)
        XCTAssertFalse(result.items.contains { $0.0 == .tiff })
    }

    func testJPEGExtensionsPublishPublicJPEGBytes() throws {
        let image = try oneByOneImage()
        let jpgBytes = Data("jpg-bytes-not-reencoded".utf8)
        let jpegBytes = Data("jpeg-bytes-not-reencoded".utf8)
        for (path, bytes) in [("shot.JPG", jpgBytes), ("shot.jpeg", jpegBytes)] {
            let broker = PasteboardBroker()
            var reads = 0
            let result = broker.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 11))
                },
                read: { _ in
                    reads += 1
                    return bytes
                }
            )
            XCTAssertEqual(reads, 1, path)
            assertNative(result, type: jpegType, bytes: bytes)
        }
    }

    func testGIFPublishesExactBytesWithoutFlattening() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        let bytes = Data("GIF89a-animated-frames-must-stay-intact".utf8)
        var reads = 0
        let result = broker.expansionImageRepresentations(
            image: image,
            imagePath: "anim.GiF",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 12))
            },
            read: { _ in
                reads += 1
                return bytes
            }
        )
        XCTAssertEqual(reads, 1)
        assertNative(result, type: gifType, bytes: bytes)
    }

    func testStoredTIFFPublishesTIFFOnly() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        let bytes = Data("raw-tiff-container-not-a-second-png".utf8)
        var reads = 0
        let result = broker.expansionImageRepresentations(
            image: image,
            imagePath: "scan.TIFF",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 13))
            },
            read: { _ in
                reads += 1
                return bytes
            }
        )
        XCTAssertEqual(reads, 1)
        assertNative(result, type: .tiff, bytes: bytes)
        XCTAssertFalse(result.items.contains { $0.0 == .png })
    }

    func testNonNativeExtensionsFallBackWithoutReading() throws {
        let image = try oneByOneImage()
        for path in ["a.bmp", "a.BMP", "a.webp", "a.heic", "a.tif", "a.TIF", "a.xyz", "noextension"] {
            let broker = PasteboardBroker()
            var reads = 0
            var stats = 0
            let result = broker.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    stats += 1
                    return PasteboardBroker.NativeImageFileAttributes(byteCount: 4, modifiedAt: Date(timeIntervalSince1970: 1))
                },
                read: { _ in
                    reads += 1
                    return Data("should-not-be-read".utf8)
                }
            )
            XCTAssertEqual(reads, 0, path)
            XCTAssertEqual(stats, 0, path)
            assertFallback(result, image: image)
        }
    }

    func testNilAndEmptyPathFallBackWithoutReading() throws {
        let image = try oneByOneImage()
        for path in [nil, ""] as [String?] {
            let broker = PasteboardBroker()
            var reads = 0
            var stats = 0
            let result = broker.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    stats += 1
                    return nil
                },
                read: { _ in
                    reads += 1
                    return Data("nope".utf8)
                }
            )
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(stats, 0)
            assertFallback(result, image: image)
        }
    }

    func testOverCapStatDoesNotReadAndFallsBack() throws {
        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        ImageAttachmentStore.maxImportedImageBytes = 10
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        var reads = 0
        let result = broker.expansionImageRepresentations(
            image: image,
            imagePath: "big.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: 11, modifiedAt: Date(timeIntervalSince1970: 20))
            },
            read: { _ in
                reads += 1
                return Data(repeating: 1, count: 11)
            }
        )
        XCTAssertEqual(reads, 0)
        assertFallback(result, image: image)
        let snapshot = broker.nativeImagePayloadCacheSnapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
        XCTAssertEqual(snapshot.payloadBytes, 0)
    }

    func testOverCapReadIsDiscardedNotCachedAndFallsBack() throws {
        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        ImageAttachmentStore.maxImportedImageBytes = 10
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        var reads = 0
        let oversized = Data(repeating: 9, count: 11)
        let call = {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: "grew.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 21))
                },
                read: { _ in
                    reads += 1
                    return oversized
                }
            )
        }
        let first = call()
        let second = call()
        XCTAssertEqual(reads, 2)
        assertFallback(first, image: image)
        assertFallback(second, image: image)
        XCTAssertFalse(first.items.contains { $0.1 == oversized })
        let snapshot = broker.nativeImagePayloadCacheSnapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
        XCTAssertEqual(snapshot.payloadBytes, 0)
    }

    func testMismatchedReadCountPublishesOnceAndDoesNotCache() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        let published = Data("short-read".utf8)
        var reads = 0
        let call = {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: "race.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: published.count + 4, modifiedAt: Date(timeIntervalSince1970: 22))
                },
                read: { _ in
                    reads += 1
                    return published
                }
            )
        }
        let first = call()
        let second = call()
        XCTAssertEqual(reads, 2)
        assertNative(first, type: .png, bytes: published)
        assertNative(second, type: .png, bytes: published)
        XCTAssertEqual(first.payloadBytes, published.count)
        let snapshot = broker.nativeImagePayloadCacheSnapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
        XCTAssertEqual(snapshot.payloadBytes, 0)
    }

    func testDotDotPathIsNotRead() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        var reads = 0
        var stats = 0
        let result = broker.expansionImageRepresentations(
            image: image,
            imagePath: "../outside.png",
            attributes: { _ in
                stats += 1
                return PasteboardBroker.NativeImageFileAttributes(byteCount: 3, modifiedAt: Date(timeIntervalSince1970: 1))
            },
            read: { _ in
                reads += 1
                return Data("secret".utf8)
            }
        )
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(stats, 0)
        XCTAssertNil(ImageAttachmentStore.shared.resolvedURL(forImagePath: "../outside.png"))
        assertFallback(result, image: image)
    }

    func testAbsolutePathIsResolvedAndRead() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        let path = "/tmp/devtype-image-bytes-\(UUID().uuidString).png"
        let bytes = Data("absolute-legacy-bytes".utf8)
        var seen: URL?
        var reads = 0
        let result = broker.expansionImageRepresentations(
            image: image,
            imagePath: path,
            attributes: { url in
                seen = url
                return PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 30))
            },
            read: { url in
                reads += 1
                XCTAssertEqual(url.path, URL(fileURLWithPath: path).path)
                return bytes
            }
        )
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(seen?.path, URL(fileURLWithPath: path).path)
        XCTAssertEqual(ImageAttachmentStore.shared.resolvedURL(forImagePath: path)?.path, URL(fileURLWithPath: path).path)
        assertNative(result, type: .png, bytes: bytes)
    }

    func testCacheHitDoesNotRereadOrRefreshAge() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        var reads: [String: Int] = [:]
        func payload(path: String, mtime: TimeInterval, size: Int) -> PasteboardBroker.ExpansionImageRepresentations {
            return broker.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: size, modifiedAt: Date(timeIntervalSince1970: mtime))
                },
                read: { _ in
                    reads[path, default: 0] += 1
                    return Data(repeating: UInt8(path.utf8.first ?? 1), count: size)
                }
            )
        }
        _ = payload(path: "a.png", mtime: 1, size: 10)
        _ = payload(path: "b.png", mtime: 1, size: 10)
        _ = payload(path: "c.png", mtime: 1, size: 10)
        _ = payload(path: "d.png", mtime: 1, size: 10)
        let hit = payload(path: "a.png", mtime: 1, size: 10)
        XCTAssertEqual(reads["a.png"], 1)
        assertNative(hit, type: .png, bytes: Data(repeating: UInt8("a".utf8.first!), count: 10))
        _ = payload(path: "e.png", mtime: 1, size: 10)
        _ = payload(path: "b.png", mtime: 1, size: 10)
        _ = payload(path: "a.png", mtime: 1, size: 10)
        XCTAssertEqual(reads["a.png"], 2, "A cache hit must not make A the newest entry")
        XCTAssertEqual(reads["b.png"], 1, "B stays cached when A was not refreshed")
        XCTAssertEqual(reads["e.png"], 1)
        let snapshot = broker.nativeImagePayloadCacheSnapshot()
        XCTAssertEqual(snapshot.entryCount, 4)
        XCTAssertEqual(snapshot.payloadBytes, 40)
    }

    func testMtimeOrSizeChangeRereadsAndReplacesThatPath() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        var reads = 0
        var current = Data("v1".utf8)
        var mtime: TimeInterval = 40
        var size = current.count
        func load() -> PasteboardBroker.ExpansionImageRepresentations {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: "same.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: size, modifiedAt: Date(timeIntervalSince1970: mtime))
                },
                read: { _ in
                    reads += 1
                    return current
                }
            )
        }
        let first = load()
        let cached = load()
        XCTAssertEqual(reads, 1)
        assertNative(cached, type: .png, bytes: first.items[0].1)
        mtime = 41
        current = Data("v2-mtime".utf8)
        size = current.count
        let afterMtime = load()
        XCTAssertEqual(reads, 2)
        assertNative(afterMtime, type: .png, bytes: current)
        current = Data("v3-size-changed".utf8)
        size = current.count
        let afterSize = load()
        XCTAssertEqual(reads, 3)
        assertNative(afterSize, type: .png, bytes: current)
        let again = load()
        XCTAssertEqual(reads, 3)
        assertNative(again, type: .png, bytes: current)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, current.count)
    }

    func testFifthPathEvictsOldestAndByteCapEvictsUntilTheNewPayloadFits() throws {
        let image = try oneByOneImage()
        let eviction = PasteboardBroker()
        var reads: [String: Int] = [:]
        func store(_ broker: PasteboardBroker, path: String, size: Int) -> PasteboardBroker.ExpansionImageRepresentations {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: size, modifiedAt: Date(timeIntervalSince1970: 7))
                },
                read: { _ in
                    reads[path, default: 0] += 1
                    return Data(repeating: UInt8(size), count: size)
                }
            )
        }
        for name in ["a.png", "b.png", "c.png", "d.png", "e.png"] {
            let result = store(eviction, path: name, size: 8)
            assertNative(result, type: .png, bytes: Data(repeating: 8, count: 8))
            XCTAssertLessThanOrEqual(eviction.nativeImagePayloadCacheSnapshot().payloadBytes, ImageAttachmentStore.maxImportedImageBytes)
            XCTAssertLessThanOrEqual(eviction.nativeImagePayloadCacheSnapshot().entryCount, 4)
        }
        XCTAssertEqual(eviction.nativeImagePayloadCacheSnapshot().entryCount, 4)
        XCTAssertEqual(eviction.nativeImagePayloadCacheSnapshot().payloadBytes, 32)
        _ = store(eviction, path: "b.png", size: 8)
        _ = store(eviction, path: "a.png", size: 8)
        XCTAssertEqual(reads["a.png"], 2)
        XCTAssertEqual(reads["b.png"], 1)

        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        ImageAttachmentStore.maxImportedImageBytes = 100
        let capped = PasteboardBroker()
        var cappedReads: [String: Int] = [:]
        func storeCapped(path: String, size: Int) -> PasteboardBroker.ExpansionImageRepresentations {
            capped.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: size, modifiedAt: Date(timeIntervalSince1970: 8))
                },
                read: { _ in
                    cappedReads[path, default: 0] += 1
                    return Data(repeating: UInt8(min(size, 255)), count: size)
                }
            )
        }
        _ = storeCapped(path: "a.png", size: 40)
        _ = storeCapped(path: "b.png", size: 40)
        XCTAssertEqual(capped.nativeImagePayloadCacheSnapshot().payloadBytes, 80)
        let overflow = storeCapped(path: "c.png", size: 90)
        assertNative(overflow, type: .png, bytes: Data(repeating: 90, count: 90))
        let snapshot = capped.nativeImagePayloadCacheSnapshot()
        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(snapshot.payloadBytes, 90)
        XCTAssertLessThanOrEqual(snapshot.payloadBytes, 100)
        _ = storeCapped(path: "c.png", size: 90)
        _ = storeCapped(path: "a.png", size: 40)
        _ = storeCapped(path: "b.png", size: 40)
        XCTAssertEqual(cappedReads["a.png"], 2)
        XCTAssertEqual(cappedReads["b.png"], 2)
        XCTAssertEqual(cappedReads["c.png"], 1)
        XCTAssertLessThanOrEqual(capped.nativeImagePayloadCacheSnapshot().payloadBytes, 100)
    }

    func testWriteUserClipboardImageStillPublishesTIFFAndPNGAndEmptyImagePreservesBoard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("original", forType: .string))
        let broker = PasteboardBroker()
        XCTAssertFalse(broker.writeUserClipboardImage(NSImage(), pasteboard: board))
        XCTAssertEqual(board.string(forType: .string), "original")
        let image = try oneByOneImage()
        XCTAssertTrue(broker.writeUserClipboardImage(image, pasteboard: board))
        XCTAssertNotNil(board.data(forType: .png))
        XCTAssertNotNil(board.data(forType: .tiff))
        XCTAssertNil(board.string(forType: .string))
    }

    func testPasteImageViaClipboardPassesPreparedPayloadBytesIntoRestoreDelay() throws {
        let brokerSource = try repoSource("Sources/ExpanderEngine/Engine/PasteboardBroker.swift")
        let imagePaste = try XCTUnwrap(brokerSource.range(of: "public func pasteImageViaClipboard("))
        let holdLoop = try XCTUnwrap(brokerSource.range(of: "private func runImageHoldLoop("))
        let body = String(brokerSource[imagePaste.lowerBound..<holdLoop.lowerBound])
        XCTAssertTrue(body.contains("imagePath: String? = nil"))
        XCTAssertTrue(body.contains("let prepared = expansionImageRepresentations(image: image, imagePath: imagePath)"))
        XCTAssertTrue(body.contains("let payloadBytes = prepared.payloadBytes"))
        XCTAssertTrue(body.contains("calculateImageRestoreDelay(payloadBytes: payloadBytes)"))
        let payload = try XCTUnwrap(body.range(of: "let payloadBytes = prepared.payloadBytes"))
        let markers = try XCTUnwrap(body.range(of: "Self.transientType"))
        let board = try XCTUnwrap(body.range(of: "NSPasteboard.general"))
        let emptyGuard = try XCTUnwrap(body.range(of: "guard !representations.isEmpty"))
        XCTAssertLessThan(payload.lowerBound, markers.lowerBound)
        XCTAssertLessThan(emptyGuard.lowerBound, board.lowerBound)
        XCTAssertFalse(body.contains("representations.reduce"))
        XCTAssertTrue(body.contains("guard shouldContinue()"))
        XCTAssertTrue(body.contains("guard CGPreflightPostEventAccess()"))
        XCTAssertTrue(body.contains("AXContextChecker.isSecureEventInputEnabledLive()"))
        XCTAssertTrue(body.contains("verifySelectionRange("))
        XCTAssertTrue(body.contains("verifyFocusedElement("))

        let pipeline = try repoSource("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift")
        XCTAssertTrue(pipeline.contains("imagePath: context.snippet.imagePath"))
        let signature = try XCTUnwrap(brokerSource.range(of: "public func pasteImageViaClipboard("))
        XCTAssertNotNil(signature)
    }

    func testMixedCaseExtensionsPublishTheExactBytesUnderOneNativeType() throws {
        let image = try oneByOneImage()
        let cases: [(String, NSPasteboard.PasteboardType, String, Data)] = [
            ("Shot.PNG", .png, "public.png", Data("png-bytes-UPPER".utf8)),
            ("Shot.JpEg", jpegType, "public.jpeg", Data("jpeg-bytes-MiXeD".utf8)),
            ("Anim.GIF", gifType, "public.gif", Data("gif-bytes-UPPER".utf8)),
            ("Scan.TIFF", .tiff, "public.tiff", Data("tiff-bytes-UPPER".utf8)),
        ]
        for (path, type, raw, bytes) in cases {
            let broker = PasteboardBroker()
            var reads = 0
            let load = {
                broker.expansionImageRepresentations(
                    image: image,
                    imagePath: path,
                    attributes: { _ in
                        PasteboardBroker.NativeImageFileAttributes(
                            byteCount: bytes.count,
                            modifiedAt: Date(timeIntervalSince1970: 70)
                        )
                    },
                    read: { _ in
                        reads += 1
                        return bytes
                    }
                )
            }
            let first = load()
            let second = load()
            XCTAssertEqual(reads, 1, path)
            assertNative(first, type: type, bytes: bytes)
            assertNative(second, type: type, bytes: bytes)
            XCTAssertEqual(first.items.map(\.0.rawValue), [raw], path)
            XCTAssertEqual(Set(first.items.map(\.0)), [type], path)
        }
    }

    func testExactlyCapIsCachedAndOverCapLeavesThatCacheUntouched() throws {
        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        let cap = 40
        ImageAttachmentStore.maxImportedImageBytes = cap
        let image = try oneByOneImage()
        let broker = PasteboardBroker()
        let exact = Data(repeating: 0x11, count: cap)
        var exactReads = 0
        let loadExact = {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: "exact.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: cap, modifiedAt: Date(timeIntervalSince1970: 71))
                },
                read: { _ in
                    exactReads += 1
                    return exact
                }
            )
        }
        assertNative(loadExact(), type: .png, bytes: exact)
        assertNative(loadExact(), type: .png, bytes: exact)
        XCTAssertEqual(exactReads, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)

        var statReads = 0
        let overStat = broker.expansionImageRepresentations(
            image: image,
            imagePath: "stat-over.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: cap + 1, modifiedAt: Date(timeIntervalSince1970: 72))
            },
            read: { _ in
                statReads += 1
                return Data(repeating: 0x22, count: cap + 1)
            }
        )
        XCTAssertEqual(statReads, 0)
        assertFallback(overStat, image: image)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)

        var grewReads = 0
        let grew = Data(repeating: 0x33, count: cap + 1)
        let overRead = broker.expansionImageRepresentations(
            image: image,
            imagePath: "grew.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: cap, modifiedAt: Date(timeIntervalSince1970: 73))
            },
            read: { _ in
                grewReads += 1
                return grew
            }
        )
        XCTAssertEqual(grewReads, 1)
        assertFallback(overRead, image: image)
        XCTAssertFalse(overRead.items.contains { $0.1 == grew })
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)
        assertNative(loadExact(), type: .png, bytes: exact)
        XCTAssertEqual(exactReads, 1, "over-cap read must not force the cached entry to be read again")

        var samePathReads = 0
        let samePathOver = broker.expansionImageRepresentations(
            image: image,
            imagePath: "exact.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: 8, modifiedAt: Date(timeIntervalSince1970: 74))
            },
            read: { _ in
                samePathReads += 1
                return Data(repeating: 0x44, count: cap + 1)
            }
        )
        XCTAssertEqual(samePathReads, 1)
        assertFallback(samePathOver, image: image)
        assertNative(loadExact(), type: .png, bytes: exact)
        XCTAssertEqual(exactReads, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)

        let filled = PasteboardBroker()
        var reads: [String: Int] = [:]
        let paths = ["a.png", "b.png", "c.png", "d.png"]
        for path in paths {
            let result = filled.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: 8, modifiedAt: Date(timeIntervalSince1970: 75))
                },
                read: { _ in
                    reads[path, default: 0] += 1
                    return Data(repeating: UInt8(path.utf8.first ?? 1), count: 8)
                }
            )
            assertNative(result, type: .png, bytes: Data(repeating: UInt8(path.utf8.first ?? 1), count: 8))
        }
        XCTAssertEqual(filled.nativeImagePayloadCacheSnapshot().entryCount, 4)
        let disturb = filled.expansionImageRepresentations(
            image: image,
            imagePath: "e.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: 8, modifiedAt: Date(timeIntervalSince1970: 76))
            },
            read: { _ in Data(repeating: 0x55, count: cap + 1) }
        )
        assertFallback(disturb, image: image)
        XCTAssertEqual(filled.nativeImagePayloadCacheSnapshot().entryCount, 4)
        XCTAssertEqual(filled.nativeImagePayloadCacheSnapshot().payloadBytes, 32)
        for path in paths {
            _ = filled.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: 8, modifiedAt: Date(timeIntervalSince1970: 75))
                },
                read: { _ in
                    reads[path, default: 0] += 1
                    return Data(repeating: 0x66, count: 8)
                }
            )
            XCTAssertEqual(reads[path], 1, path)
        }
    }

    func testASecondBrokerDoesNotSeeTheFirstCache() throws {
        let image = try oneByOneImage()
        let bytes = Data("broker-local-bytes".utf8)
        let first = PasteboardBroker()
        let second = PasteboardBroker()
        var firstReads = 0
        var secondReads = 0
        let attributes: (URL) -> PasteboardBroker.NativeImageFileAttributes? = { _ in
            PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 77))
        }
        let firstResult = first.expansionImageRepresentations(
            image: image, imagePath: "local.png", attributes: attributes,
            read: { _ in firstReads += 1; return bytes }
        )
        assertNative(firstResult, type: .png, bytes: bytes)
        XCTAssertEqual(second.nativeImagePayloadCacheSnapshot().entryCount, 0)
        XCTAssertEqual(second.nativeImagePayloadCacheSnapshot().payloadBytes, 0)
        let secondResult = second.expansionImageRepresentations(
            image: image, imagePath: "local.png", attributes: attributes,
            read: { _ in secondReads += 1; return bytes }
        )
        XCTAssertEqual(firstReads, 1)
        XCTAssertEqual(secondReads, 1)
        assertNative(secondResult, type: .png, bytes: bytes)
        _ = first.expansionImageRepresentations(
            image: image, imagePath: "local.png", attributes: attributes,
            read: { _ in firstReads += 1; return Data("replacement".utf8) }
        )
        XCTAssertEqual(firstReads, 1)
        XCTAssertEqual(second.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(first.nativeImagePayloadCacheSnapshot().entryCount, 1)
    }

    func testRejectedPathsStayUncachedAfterRepeatedCalls() throws {
        let image = try oneByOneImage()
        let broker = PasteboardBroker()
        let secret = Data("rejected-secret-bytes".utf8)
        let paths: [String?] = ["a.bmp", "a.webp", "a.heic", "a.tif", "a.xyz", "noextension", nil, "", "../x.png", "foo..png"]
        for path in paths {
            var reads = 0
            var stats = 0
            for _ in 0..<2 {
                let result = broker.expansionImageRepresentations(
                    image: image,
                    imagePath: path,
                    attributes: { _ in
                        stats += 1
                        return PasteboardBroker.NativeImageFileAttributes(byteCount: secret.count, modifiedAt: Date(timeIntervalSince1970: 78))
                    },
                    read: { _ in
                        reads += 1
                        return secret
                    }
                )
                XCTAssertEqual(reads, 0, path ?? "nil")
                XCTAssertEqual(stats, 0, path ?? "nil")
                assertFallback(result, image: image)
                XCTAssertFalse(result.items.contains { $0.1 == secret })
                XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 0, path ?? "nil")
                XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, 0, path ?? "nil")
            }
        }
    }

    func testDotSlashAndPlainRelativePathShareACacheEntryWhenTheyStandardizeTogether() throws {
        let image = try oneByOneImage()
        let plain = ImageAttachmentStore.shared.resolvedURL(forImagePath: "foo.png")?.standardizedFileURL.path
        let dotted = ImageAttachmentStore.shared.resolvedURL(forImagePath: "./foo.png")?.standardizedFileURL.path
        XCTAssertNotNil(plain)
        XCTAssertNotNil(dotted)
        let broker = PasteboardBroker()
        let bytes = Data("relative-same-bytes".utf8)
        var reads = 0
        func load(_ path: String) -> PasteboardBroker.ExpansionImageRepresentations {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: path,
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 79))
                },
                read: { _ in
                    reads += 1
                    return bytes
                }
            )
        }
        let first = load("foo.png")
        let second = load("./foo.png")
        assertNative(first, type: .png, bytes: bytes)
        assertNative(second, type: .png, bytes: bytes)
        if plain == dotted {
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
            XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, bytes.count)
        } else {
            XCTAssertNotEqual(plain, dotted)
            XCTAssertEqual(reads, 2)
        }
    }

    func testSameStatServesStaleBytesAndALongerInCapReadIsNotCached() throws {
        let image = try oneByOneImage()
        let broker = PasteboardBroker()
        var reads = 0
        var current = Data("stale-v1".utf8)
        let load = {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: "stale.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: current.count, modifiedAt: Date(timeIntervalSince1970: 80))
                },
                read: { _ in
                    reads += 1
                    return current
                }
            )
        }
        assertNative(load(), type: .png, bytes: Data("stale-v1".utf8))
        current = Data("stale-v2".utf8)
        assertNative(load(), type: .png, bytes: Data("stale-v1".utf8))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(current.count, Data("stale-v1".utf8).count)

        let mismatched = PasteboardBroker()
        var mismatchReads = 0
        let shortStat = 4
        let longer = Data("longer!".utf8)
        XCTAssertGreaterThan(longer.count, shortStat)
        XCTAssertLessThanOrEqual(longer.count, ImageAttachmentStore.maxImportedImageBytes)
        let call = {
            mismatched.expansionImageRepresentations(
                image: image,
                imagePath: "mismatch.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: shortStat, modifiedAt: Date(timeIntervalSince1970: 81))
                },
                read: { _ in
                    mismatchReads += 1
                    return longer
                }
            )
        }
        assertNative(call(), type: .png, bytes: longer)
        assertNative(call(), type: .png, bytes: longer)
        XCTAssertEqual(mismatchReads, 2)
        XCTAssertEqual(mismatched.nativeImagePayloadCacheSnapshot().entryCount, 0)
    }

    func testNilReadAndNegativeStatDoNotEvictACachedEntry() throws {
        let image = try oneByOneImage()
        let broker = PasteboardBroker()
        let cached = Data("kept-bytes".utf8)
        var keepReads = 0
        let keep = {
            broker.expansionImageRepresentations(
                image: image,
                imagePath: "keep.png",
                attributes: { _ in
                    PasteboardBroker.NativeImageFileAttributes(byteCount: cached.count, modifiedAt: Date(timeIntervalSince1970: 82))
                },
                read: { _ in
                    keepReads += 1
                    return cached
                }
            )
        }
        assertNative(keep(), type: .png, bytes: cached)
        var nilReads = 0
        let missing = broker.expansionImageRepresentations(
            image: image,
            imagePath: "keep.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: cached.count, modifiedAt: Date(timeIntervalSince1970: 83))
            },
            read: { _ in
                nilReads += 1
                return nil
            }
        )
        XCTAssertEqual(nilReads, 1)
        assertFallback(missing, image: image)
        assertNative(keep(), type: .png, bytes: cached)
        XCTAssertEqual(keepReads, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)

        var negativeReads = 0
        let negative = broker.expansionImageRepresentations(
            image: image,
            imagePath: "negative.png",
            attributes: { _ in
                PasteboardBroker.NativeImageFileAttributes(byteCount: -1, modifiedAt: Date(timeIntervalSince1970: 84))
            },
            read: { _ in
                negativeReads += 1
                return cached
            }
        )
        XCTAssertEqual(negativeReads, 0)
        assertFallback(negative, image: image)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cached.count)
        assertNative(keep(), type: .png, bytes: cached)
        XCTAssertEqual(keepReads, 1)
    }

    func testDefaultReaderPublishesFileBytesAndDoesNotRewriteOrRecacheAHeldStat() throws {
        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        let cap = 64
        ImageAttachmentStore.maxImportedImageBytes = cap
        let image = try oneByOneImage()
        let broker = PasteboardBroker()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-image-bytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let smallURL = root.appendingPathComponent("shot copy.JpEg")
        let stored = Data((0..<24).map { UInt8($0) })
        let mutated = Data((0..<24).map { UInt8(255 &- $0) })
        let rewritten = Data((0..<20).map { UInt8($0 &+ 9) })
        XCTAssertNotEqual(stored, mutated)
        XCTAssertEqual(stored.count, mutated.count)
        XCTAssertLessThan(rewritten.count, cap)
        try stored.write(to: smallURL)
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: anchor], ofItemAtPath: smallURL.path)
        let observed = try fileModificationDate(smallURL)

        let first = broker.expansionImageRepresentations(image: image, imagePath: smallURL.path)
        assertNative(first, type: jpegType, bytes: stored)
        XCTAssertEqual(first.items.map(\.0.rawValue), ["public.jpeg"])
        let second = broker.expansionImageRepresentations(image: image, imagePath: smallURL.path)
        assertNative(second, type: jpegType, bytes: stored)
        XCTAssertEqual(try Data(contentsOf: smallURL), stored)

        try mutated.write(to: smallURL)
        try FileManager.default.setAttributes([.modificationDate: observed], ofItemAtPath: smallURL.path)
        let afterRewrite = try fileModificationDate(smallURL)
        let heldSize = try fileByteCount(smallURL) == stored.count
        let heldMtime = afterRewrite == observed
        let third = broker.expansionImageRepresentations(image: image, imagePath: smallURL.path)
        if heldMtime && heldSize {
            assertNative(third, type: jpegType, bytes: stored)
            XCTAssertEqual(try Data(contentsOf: smallURL), mutated)
        } else {
            XCTFail("could not preserve size=\(heldSize) mtime held=\(heldMtime) observed=\(observed.timeIntervalSince1970) after=\(afterRewrite.timeIntervalSince1970)")
        }

        try rewritten.write(to: smallURL)
        try FileManager.default.setAttributes(
            [.modificationDate: observed.addingTimeInterval(5)],
            ofItemAtPath: smallURL.path
        )
        let fourth = broker.expansionImageRepresentations(image: image, imagePath: smallURL.path)
        assertNative(fourth, type: jpegType, bytes: rewritten)
        XCTAssertEqual(try Data(contentsOf: smallURL), rewritten)

        let exactURL = root.appendingPathComponent("exact.PNG")
        let exact = Data(repeating: 0x5A, count: cap)
        let exactMutated = Data(repeating: 0xA5, count: cap)
        try exact.write(to: exactURL)
        try FileManager.default.setAttributes([.modificationDate: anchor], ofItemAtPath: exactURL.path)
        let exactMtime = try fileModificationDate(exactURL)
        let exactResult = broker.expansionImageRepresentations(image: image, imagePath: exactURL.path)
        assertNative(exactResult, type: .png, bytes: exact)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)

        let overURL = root.appendingPathComponent("over.png")
        let over = Data(repeating: 0x22, count: cap + 1)
        try over.write(to: overURL)
        let overResult = broker.expansionImageRepresentations(image: image, imagePath: overURL.path)
        assertFallback(overResult, image: image)
        XCTAssertFalse(overResult.items.contains { $0.1 == over })
        XCTAssertFalse(overResult.items.contains { $0.1 == Data(over.prefix(cap)) })
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)

        try exactMutated.write(to: exactURL)
        try FileManager.default.setAttributes([.modificationDate: exactMtime], ofItemAtPath: exactURL.path)
        let exactAfter = try fileModificationDate(exactURL)
        let exactSize = try fileByteCount(exactURL)
        let exactHeld = exactAfter == exactMtime && exactSize == cap
        let exactAgain = broker.expansionImageRepresentations(image: image, imagePath: exactURL.path)
        if exactHeld {
            assertNative(exactAgain, type: .png, bytes: exact)
            XCTAssertEqual(try Data(contentsOf: exactURL), exactMutated)
        } else {
            XCTFail("exact-cap stat was not preserved after=\(exactAfter.timeIntervalSince1970) original=\(exactMtime.timeIntervalSince1970)")
        }
        let overAgain = broker.expansionImageRepresentations(image: image, imagePath: overURL.path)
        assertFallback(overAgain, image: image)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, cap)
    }

    func testDirectoryMissingAndUnreadableFilesFallBackWithoutCaching() throws {
        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        ImageAttachmentStore.maxImportedImageBytes = 64
        let image = try oneByOneImage()
        let broker = PasteboardBroker()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-image-bytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locked = root.appendingPathComponent("locked.TIFF")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let directory = root.appendingPathComponent("folder.PNG", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<2 {
            let result = broker.expansionImageRepresentations(image: image, imagePath: directory.path)
            assertFallback(result, image: image)
            XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 0)
        }

        let missing = root.appendingPathComponent("missing.GIF").path
        for _ in 0..<2 {
            let result = broker.expansionImageRepresentations(image: image, imagePath: missing)
            assertFallback(result, image: image)
            XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 0)
        }

        try Data("secret-tiff".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        for _ in 0..<2 {
            let result = broker.expansionImageRepresentations(image: image, imagePath: locked.path)
            assertFallback(result, image: image)
            XCTAssertFalse(result.items.contains { $0.1 == Data("secret-tiff".utf8) })
            XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 0)
        }
    }

    func testCacheLockIsNotHeldAcrossAttributeOrReadIO() throws {
        let broker = PasteboardBroker()
        let image = try oneByOneImage()
        let bytes = Data("lock-probe".utf8)
        let enteredAttributes = DispatchSemaphore(value: 0)
        let releaseAttributes = DispatchSemaphore(value: 0)
        let enteredRead = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        defer {
            releaseAttributes.signal()
            releaseRead.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = broker.expansionImageRepresentations(
                image: image,
                imagePath: "lock.png",
                attributes: { _ in
                    enteredAttributes.signal()
                    releaseAttributes.wait()
                    return PasteboardBroker.NativeImageFileAttributes(
                        byteCount: bytes.count,
                        modifiedAt: Date(timeIntervalSince1970: 90)
                    )
                },
                read: { _ in
                    enteredRead.signal()
                    releaseRead.wait()
                    return bytes
                }
            )
            done.signal()
        }
        XCTAssertEqual(enteredAttributes.wait(timeout: .now() + 2), .success)
        let duringAttributes = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = broker.nativeImagePayloadCacheSnapshot()
            duringAttributes.signal()
        }
        let attributesFree = duringAttributes.wait(timeout: .now() + 1)
        releaseAttributes.signal()
        XCTAssertEqual(attributesFree, .success, "cache lock held across attribute IO")

        XCTAssertEqual(enteredRead.wait(timeout: .now() + 2), .success)
        let duringRead = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = broker.nativeImagePayloadCacheSnapshot()
            XCTAssertEqual(snapshot.entryCount, 0)
            duringRead.signal()
        }
        let readFree = duringRead.wait(timeout: .now() + 1)
        releaseRead.signal()
        XCTAssertEqual(readFree, .success, "cache lock held across read IO")
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(broker.nativeImagePayloadCacheSnapshot().payloadBytes, bytes.count)
    }

    func testConcurrentStoresStayWithinEntryAndByteCaps() throws {
        let original = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = original }
        let cap = 64
        ImageAttachmentStore.maxImportedImageBytes = cap
        let image = try oneByOneImage()
        let queues = [
            DispatchQueue(label: "devtype.image-bytes.a", attributes: .concurrent),
            DispatchQueue(label: "devtype.image-bytes.b", attributes: .concurrent),
        ]
        let same = PasteboardBroker()
        let samePayload = Data(repeating: 7, count: 16)
        let sameGroup = DispatchGroup()
        for index in 0..<16 {
            sameGroup.enter()
            queues[index % 2].async {
                defer { sameGroup.leave() }
                _ = same.expansionImageRepresentations(
                    image: image,
                    imagePath: "same.png",
                    attributes: { _ in
                        PasteboardBroker.NativeImageFileAttributes(byteCount: samePayload.count, modifiedAt: Date(timeIntervalSince1970: 91))
                    },
                    read: { _ in samePayload }
                )
            }
        }
        XCTAssertEqual(sameGroup.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(same.nativeImagePayloadCacheSnapshot().entryCount, 1)
        XCTAssertEqual(same.nativeImagePayloadCacheSnapshot().payloadBytes, samePayload.count)

        let broker = PasteboardBroker()
        let witness = CacheCapWitness()
        let samplerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { samplerDone.signal() }
            while witness.shouldStop() == false {
                let snapshot = broker.nativeImagePayloadCacheSnapshot()
                witness.record(entryCount: snapshot.entryCount, payloadBytes: snapshot.payloadBytes, cap: cap)
            }
        }
        defer { witness.finish() }
        let group = DispatchGroup()
        let itemSize = 24
        for index in 0..<32 {
            group.enter()
            queues[index % 2].async {
                defer { group.leave() }
                _ = broker.expansionImageRepresentations(
                    image: image,
                    imagePath: "c\(index).png",
                    attributes: { _ in
                        PasteboardBroker.NativeImageFileAttributes(byteCount: itemSize, modifiedAt: Date(timeIntervalSince1970: 92))
                    },
                    read: { _ in Data(repeating: UInt8(index % 200), count: itemSize) }
                )
                let snapshot = broker.nativeImagePayloadCacheSnapshot()
                witness.record(entryCount: snapshot.entryCount, payloadBytes: snapshot.payloadBytes, cap: cap)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        witness.finish()
        XCTAssertEqual(samplerDone.wait(timeout: .now() + 2), .success)
        let snapshot = broker.nativeImagePayloadCacheSnapshot()
        XCTAssertLessThanOrEqual(snapshot.entryCount, 4)
        XCTAssertLessThanOrEqual(snapshot.payloadBytes, cap)
        XCTAssertFalse(witness.violated)
        XCTAssertGreaterThan(witness.samples, 0)
        XCTAssertGreaterThan(snapshot.entryCount, 0)
        XCTAssertEqual(snapshot.payloadBytes % itemSize, 0)
    }

    private func fileModificationDate(_ url: URL) throws -> Date {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(values[.modificationDate] as? Date)
    }

    private func fileByteCount(_ url: URL) throws -> Int {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = values[.size] as? Int64 { return Int(size) }
        if let size = values[.size] as? Int { return size }
        if let size = values[.size] as? NSNumber { return size.intValue }
        XCTFail("missing file size")
        return -1
    }
}

/// Records whether a concurrent snapshot ever crossed the cache caps.
private final class CacheCapWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var stop = false
    private(set) var violated = false
    private(set) var samples = 0

    func record(entryCount: Int, payloadBytes: Int, cap: Int) {
        lock.lock()
        samples += 1
        if entryCount > 4 || payloadBytes > cap || payloadBytes < 0 || entryCount < 0 {
            violated = true
        }
        lock.unlock()
    }

    func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stop
    }

    func finish() {
        lock.lock()
        stop = true
        lock.unlock()
    }
}
