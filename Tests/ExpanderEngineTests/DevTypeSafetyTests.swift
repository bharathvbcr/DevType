import AppKit
import DevTypeSafety
import Security
import XCTest

final class DevTypeSafetyTests: XCTestCase {
    func testMakeKeyAndOrderFrontCatchingExceptionOnValidWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let exception = DTMakeKeyAndOrderFrontCatchingException(window)
        XCTAssertNil(exception)
    }

    func testOrderFrontRegardlessCatchingExceptionOnValidWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let exception = DTOrderFrontRegardlessCatchingException(window)
        XCTAssertNil(exception)
    }

    /// Toast and the voice HUD must order front without becoming key. A Swift
    /// subclass that raises would abort, so the raising window itself is ObjC
    /// (`DevTypeSafetyTestsRaisingWindow`). This locks the call sites.
    func testNonActivatingPanelsUseOrderFrontCatchOnly() throws {
        let toast = try source("Sources/DevTypeAppCore/ToastPanel.swift")
        let voice = try source("Sources/DevTypeAppCore/VoiceHUDPanel.swift")
        for (name, text) in [("ToastPanel.swift", toast), ("VoiceHUDPanel.swift", voice)] {
            XCTAssertFalse(
                text.contains("makeKeyAndOrderFront"),
                "\(name) must not become key"
            )
            XCTAssertFalse(
                text.contains("NSApp.activate"),
                "\(name) must not activate the app"
            )
            XCTAssertFalse(text.contains("showWindow"), "\(name) must not order via showWindow")
            XCTAssertTrue(
                text.contains("canBecomeKey: Bool { false }"),
                "\(name) must refuse key"
            )
            XCTAssertTrue(
                text.contains("DTOrderFrontRegardlessCatchingException"),
                "\(name) must order front through the non-activating catch"
            )
        }
    }

    /// Every production Swift `makeKeyAndOrderFront` / `orderFrontRegardless` send
    /// goes through an ObjC `@catch`. The catch functions' names do not contain
    /// the raw selector followed by `(`.
    func testProductionSwiftOrderFrontSendsAreCaught() throws {
        var raw: [String] = []
        var swiftFiles = 0
        for url in try enumerateRegularSources() where url.pathExtension == "swift" {
            swiftFiles += 1
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            let text = SourceContractTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
            // The helper's own declaration and its call sites are the catch.
            // What remains is a direct AppKit send (`receiver.makeKeyAndOrderFront(`
            // or `orderFrontRegardless(`). The ObjC function names use a capital
            // `Order`, so they do not match the raw selector.
            let withoutHelper = text
                .replacingOccurrences(of: "WindowOrdering.makeKeyAndOrderFront(", with: "")
                .replacingOccurrences(of: "func makeKeyAndOrderFront(", with: "")
            if withoutHelper.contains("makeKeyAndOrderFront(") || text.contains("orderFrontRegardless(") {
                raw.append(relative)
            }
        }
        XCTAssertGreaterThan(swiftFiles, 0, "A scan that saw no Swift files did not run")
        XCTAssertEqual(raw, [], "Raw window ordering must go through DevTypeSafety: \(raw)")
    }

    /// `NSWindowController.showWindow` orders on the Swift caller. An exception
    /// there aborts before the ObjC catch runs. `showWindow(` covers both
    /// `.showWindow(` and a bare `showWindow(nil)` on `self`.
    func testProductionShowWindowDoesNotOrderFromSwift() throws {
        var hits: [String] = []
        for url in try enumerateRegularSources() {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            // `try`, not `try?`: a non-UTF-8 or unreadable file fails the test.
            // A binary that cannot be decoded must not be skipped into a pass.
            let text = try String(contentsOf: url, encoding: .utf8)
            if try containsRegex(#"showWindow\s*\("#, in: text) {
                hits.append(relative)
            }
        }
        XCTAssertEqual(hits, [], "showWindow orders through Swift and must not remain: \(hits)")
    }

    /// Whitespace, `orderFront(`, `makeKey(`, `.order(`, `orderWindow`, and selector
    /// strings are not covered by an exact `makeKeyAndOrderFront(` search.
    func testSwiftOrderingSelectorsCannotBypassTheCatch() throws {
        let patterns = [
            #"makeKeyAndOrderFront\s*\("#,
            #"orderFrontRegardless\s*\("#,
            #"(?<![A-Za-z0-9_])orderFront\s*\("#,
            #"(?<![A-Za-z0-9_])makeKey\s*\("#,
            #"\.order\s*\("#,
            #"orderWindow"#,
            #"showWindow\s*\("#,
            #"makeKeyAndOrderFront:"#,
            #"orderFrontRegardless:"#,
            #"showWindow:"#,
            #"(?<![A-Za-z0-9_])orderFront:"#,
            #"(?<![A-Za-z0-9_])makeKey:"#,
            #"orderWindow:"#,
            #"NSSelectorFromString\s*\(\s*\"[^\"]*(orderFront|makeKey|showWindow|orderWindow)"#,
            #"#selector\s*\([^)\n]*(orderFront|makeKey|showWindow|orderWindow)"#,
            #"\.perform\s*\([^)\n]{0,120}(orderFront|makeKeyAndOrderFront|showWindow|orderWindow)"#,
        ]
        var hits: [String] = []
        for url in try enumerateRegularSources() {
            let ext = url.pathExtension
            guard ext == "swift" || ext == "m" || ext == "mm" || ext == "h" else { continue }
            // The trampoline is the only production file allowed to send these.
            if url.lastPathComponent == "DevTypeSafety.m" { continue }
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            let text = SourceContractTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
            let withoutHelper = text
                .replacingOccurrences(
                    of: #"WindowOrdering\s*\.\s*makeKeyAndOrderFront\s*\("#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"func\s+makeKeyAndOrderFront\s*\("#,
                    with: "",
                    options: .regularExpression
                )
            for pattern in patterns where try containsRegex(pattern, in: withoutHelper) {
                hits.append("\(relative) [\(pattern)]")
            }
        }
        XCTAssertEqual(hits, [], "Swift ordering must stay on the ObjC trampoline: \(hits)")
    }

    func testNilWindowGuardPrecedesNonNullTrampoline() throws {
        let text = try source("Sources/DevTypeAppCore/WindowOrdering.swift")
        guard let fnStart = text.range(of: "static func makeKeyAndOrderFront("),
              let fnEnd = text.range(of: "static func logCaught(")
        else {
            return XCTFail("WindowOrdering.makeKeyAndOrderFront no longer has the expected shape")
        }
        let body = text[fnStart.lowerBound..<fnEnd.lowerBound]
        guard let guardAt = body.range(of: "guard let window else { return }"),
              let callAt = body.range(of: "DTMakeKeyAndOrderFrontCatchingException(window)")
        else {
            return XCTFail("nil guard or non-null trampoline call is missing")
        }
        XCTAssertLessThan(guardAt.lowerBound, callAt.lowerBound)
        XCTAssertFalse(body.contains("DTMakeKeyAndOrderFrontCatchingException(nil)"))
        XCTAssertFalse(text.contains("void (^"))
        XCTAssertFalse(text.contains("{ ("))
    }

    func testMakeKeyTrampolineTriesBothAndRegardlessDoesNotMakeKey() throws {
        let url = repoRoot.appendingPathComponent("Sources/DevTypeSafety/DevTypeSafety.m")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let makeStart = text.range(of: "NSException *DTMakeKeyAndOrderFrontCatchingException"),
              let regardlessStart = text.range(of: "NSException *DTOrderFrontRegardlessCatchingException"),
              makeStart.lowerBound < regardlessStart.lowerBound
        else {
            return XCTFail("order-front catch functions missing")
        }
        let makeBody = text[makeStart.lowerBound..<regardlessStart.lowerBound]
        XCTAssertTrue(makeBody.contains("@try"))
        XCTAssertTrue(makeBody.contains("[window makeKeyAndOrderFront:nil];"))
        XCTAssertTrue(makeBody.contains("[window orderFrontRegardless];"))
        XCTAssertTrue(makeBody.contains("@catch"))
        let rest = text[regardlessStart.lowerBound...]
        guard let next = rest.range(of: "\nBOOL DTSetValueForKeyCatching") else {
            return XCTFail("regardless function is not bounded by DTSetValueForKeyCatching")
        }
        let regardlessBody = rest[..<next.lowerBound]
        XCTAssertTrue(regardlessBody.contains("@try"))
        XCTAssertTrue(regardlessBody.contains("[window orderFrontRegardless];"))
        XCTAssertFalse(regardlessBody.contains("makeKeyAndOrderFront"))
        XCTAssertFalse(text.contains("void (^"))
    }

    /// SwiftPM rejects a mixed test target. The raising window has to stay ObjC
    /// and in its own target, or the catch test aborts instead of asserting.
    func testRaisingOrderFrontTestStaysObjCOnly() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("name: \"DevTypeSafetyOrderFrontTests\""))
        let objcDir = repoRoot.appendingPathComponent("Tests/DevTypeSafetyOrderFrontTests")
        let names = try FileManager.default.contentsOfDirectory(atPath: objcDir.path)
        let visible = names.filter { !$0.hasPrefix(".") }
        XCTAssertFalse(visible.isEmpty)
        for name in visible {
            XCTAssertTrue(
                name.hasSuffix(".m") || name.hasSuffix(".h"),
                "\(name) mixes another language into the ObjC order-front test target"
            )
        }
        for dir in ["Tests/ExpanderEngineTests", "Tests/DevTypeAppTests"] {
            let path = repoRoot.appendingPathComponent(dir).path
            let nested = try FileManager.default.subpathsOfDirectory(atPath: path)
            XCTAssertFalse(
                nested.contains { $0.hasSuffix("DevTypeSafetyTestsRaisingWindow.m") },
                "raising window moved into a Swift test target"
            )
        }
    }

    private enum SourceScanError: Error {
        case failed
    }

    /// Regular files under `Sources`. Missing attributes, a non-URL entry, or an
    /// empty walk fail the test. Callers decode with `try` so a non-UTF-8 file
    /// fails too. Hidden files are not part of this walk.
    private func enumerateRegularSources() throws -> [URL] {
        let sources = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(sources.path)")
            throw SourceScanError.failed
        }
        var files: [URL] = []
        for entry in enumerator {
            guard let url = entry as? URL else {
                XCTFail("Enumerator yielded a non-URL under \(sources.path)")
                throw SourceScanError.failed
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard let isFile = values.isRegularFile else {
                XCTFail("isRegularFile unavailable for \(url.path)")
                throw SourceScanError.failed
            }
            if isFile {
                files.append(url)
            }
        }
        if files.isEmpty {
            XCTFail("Enumeration of \(sources.path) produced no regular files")
            throw SourceScanError.failed
        }
        return files
    }

    private func containsRegex(_ pattern: String, in text: String) throws -> Bool {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return SourceContractTests.strippingComments(text)
    }

    func testSetValueForKeyCatchingValidAndInvalidKeys() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let success = DTSetValueForKeyCatching(window, "Test Title", "title")
        XCTAssertTrue(success)
        XCTAssertEqual(window.title, "Test Title")

        let obj = NSObject()
        let failed = DTSetValueForKeyCatching(obj, "Value", "invalidNonexistentKey123")
        XCTAssertFalse(failed)
    }

    func testKeychainUserInteractionAllowedRoundTrip() {
        var original: DarwinBoolean = false
        let getStatus = DTKeychainGetUserInteractionAllowed(&original)
        if getStatus == errSecSuccess {
            let setStatus = DTKeychainSetUserInteractionAllowed(original.boolValue)
            XCTAssertEqual(setStatus, errSecSuccess)
        }
    }

    func testKeychainGetDefaultStatus() {
        var status: SecKeychainStatus = 0
        _ = DTKeychainGetDefaultStatus(&status)
    }
}
