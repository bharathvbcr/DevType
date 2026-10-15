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
}
