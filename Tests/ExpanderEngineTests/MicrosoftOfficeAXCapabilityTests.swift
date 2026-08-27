import XCTest
@testable import ExpanderEngine

/// Tests ensuring Microsoft Office applications (Word, Excel, PowerPoint, Outlook, OneNote, etc.)
/// and non-native document processors correctly seed as `.falseSuccess` and bypass AX selected-text writes.
final class MicrosoftOfficeAXCapabilityTests: XCTestCase {

    // MARK: - Microsoft Office suite seeding

    func testMicrosoftOfficeAppsSeedAsFalseSuccess() {
        let officeBundleIDs = [
            "com.microsoft.Word",
            "com.microsoft.Excel",
            "com.microsoft.Powerpoint",
            "com.microsoft.PowerPoint",
            "com.microsoft.Outlook",
            "com.microsoft.onenote.mac",
            "com.microsoft.rdc.macos",
            "com.microsoft.rdc.mac",
            "com.microsoft.to-do-mac",
            "com.microsoft.SkypeForBusiness",
            "com.microsoft.CompanyPortalMac",
        ]

        for bundleID in officeBundleIDs {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess so it skips broken AX selected-text writes"
            )
            XCTAssertTrue(
                SelectionReader.isWeakAXApp(bundleID: bundleID),
                "\(bundleID) must be recognized as a weak-AX app by SelectionReader"
            )
            XCTAssertTrue(
                TextInjectionPipeline.shouldSkipAXSelectedText(bundleID: bundleID, role: "AXTextArea"),
                "\(bundleID) must skip AX selected-text writes in TextInjectionPipeline"
            )
            XCTAssertTrue(
                AXWriteCapabilityStore().shouldSkipAXSelectedText(bundleID: bundleID, role: "AXTextArea"),
                "\(bundleID) in AXWriteCapabilityStore must return true for shouldSkipAXSelectedText"
            )
        }
    }

    func testCaseInsensitiveMicrosoftPrefixMatching() {
        let mixedCaseIDs = [
            "COM.MICROSOFT.WORD",
            "Com.Microsoft.Word",
            "com.microsoft.excel",
            "COM.MICROSOFT.POWERPOINT",
            "com.Microsoft.Outlook",
            "com.microsoft.ONENOTE.mac",
        ]

        for bundleID in mixedCaseIDs {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "Case variant \(bundleID) must resolve to .falseSuccess"
            )
        }
    }

    func testNonNativeOfficeSuitesSeedAsFalseSuccess() {
        let otherDocSuites = [
            "org.libreoffice.script",
            "org.openoffice.script",
            "com.kingsoft.wpsoffice.mac",
        ]

        for bundleID in otherDocSuites {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
        }
    }

    func testNativeCocoaAppsRetainUnknownSeed() {
        let nativeApps = [
            "com.apple.Notes",
            "com.apple.TextEdit",
            "com.apple.mail",
            "com.apple.Safari.WebApp.Helper",
            "com.example.unrelatedapp",
        ]

        for bundleID in nativeApps {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .unknown,
                "\(bundleID) must stay .unknown so honest AX writes can be verified"
            )
        }
    }

    // MARK: - Stress & Boundary Testing

    func testMicrosoftPrefixBoundaryEdgeCases() {
        // Must NOT match things that merely contain "com.microsoft" in the middle or end
        let boundaryFalseIDs = [
            "com.example.com.microsoft.app",
            "org.fake.microsoft.Word",
            "com.microsoftextra.app",
        ]

        for bundleID in boundaryFalseIDs {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .unknown,
                "\(bundleID) must not accidentally match the com.microsoft. prefix"
            )
        }
    }

    func testMayWriteViaAXDisallowsOfficeApps() {
        let store = AXWriteCapabilityStore()
        let wordBundle = "com.microsoft.Word"
        let preferHID = store.shouldSkipAXSelectedText(bundleID: wordBundle, role: "AXTextArea")
        XCTAssertTrue(preferHID, "Microsoft Word must prefer HID paste")
        XCTAssertFalse(
            TextInjectionPipeline.mayWriteViaAX(shellLike: false, preferHID: preferHID),
            "mayWriteViaAX must be false for Microsoft Word"
        )
    }

    func testDeliveryTrustSuppressedForOfficeApps() {
        let store = AXWriteCapabilityStore()
        let officeApps = [
            "com.microsoft.Word",
            "com.microsoft.Excel",
            "com.microsoft.PowerPoint",
            "com.microsoft.Outlook",
            "com.microsoft.onenote.mac",
        ]

        for app in officeApps {
            // Because Word/Office are false-success apps, their AX reads must not drive duplicate re-pastes
            XCTAssertFalse(
                store.canConfirmDelivery(bundleID: app, role: "AXTextArea"),
                "\(app) cannot confirm delivery because it is a known false-success host"
            )
            XCTAssertFalse(
                store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea"),
                "\(app) must not act on delivery failure to prevent duplicate injection"
            )
        }
    }

    func testOfficePWACanonicalizationAndVerdict() {
        let edgePWA = "com.microsoft.edgemac.app.abcdefghijklmnopabcdefghijklmnop"
        XCTAssertEqual(AXWriteCapabilityStore.canonicalBundleID(edgePWA), "com.microsoft.edgemac")
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: edgePWA), .falseSuccess)
        XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: edgePWA))

        let store = AXWriteCapabilityStore()
        XCTAssertEqual(store.verdict(for: edgePWA, role: "AXTextArea"), .falseSuccess)
    }

    func testMozillaFirefoxEcosystem() {
        let mozillaApps = [
            "org.mozilla.firefox",
            "org.mozilla.nightly",
            "org.mozilla.developerEdition",
            "org.torproject.torbrowser",
            "org.mozilla.thunderbird",
        ]

        for bundleID in mozillaApps {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
            XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: bundleID))
        }
    }

    func testJetBrainsAndJavaIDEs() {
        let jetbrainsApps = [
            "com.jetbrains.intellij",
            "com.jetbrains.intellij.ce",
            "com.jetbrains.pycharm",
            "com.jetbrains.webstorm",
            "com.jetbrains.clion",
            "com.jetbrains.goland",
            "com.jetbrains.rider",
            "com.jetbrains.fleet",
            "com.google.android.studio",
        ]

        for bundleID in jetbrainsApps {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
            XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: bundleID))
        }
    }

    func testProductivityAndNoteApps() {
        let productivityApps = [
            "notion.id",
            "com.notion.id",
            "com.notion.mac",
            "md.obsidian",
            "com.logseq.app",
            "com.linear",
            "com.linear.client",
            "com.evernote.Evernote",
            "com.clickup.desktop-app",
            "com.asana.app",
        ]

        for bundleID in productivityApps {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
            XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: bundleID))
        }
    }

    func testDesignAndCreativeTools() {
        let creativeApps = [
            "com.figma.Desktop",
            "com.canva.canvadesktop",
            "com.adobe.Acrobat.Pro",
            "com.adobe.Reader",
            "com.adobe.Photoshop",
            "com.adobe.Illustrator",
            "com.postmanlabs.mac",
            "com.insomnia.app",
            "com.axosoft.gitkraken",
            "dev.zed.Zed",
            "com.sublimetext.4",
            "com.sublimemerge",
        ]

        for bundleID in creativeApps {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
            XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: bundleID))
        }
    }

    func testCommunicationAndChatApps() {
        let chatApps = [
            "org.whispersystems.signal-desktop",
            "ru.keepcoder.Telegram",
            "org.telegram.desktop",
            "us.zoom.xos",
            "com.discord",
            "com.hammerandchisel.discord",
        ]

        for bundleID in chatApps {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
            XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: bundleID))
        }
    }

    func testAIClientsAndWebBrowsers() {
        let aiAndBrowsers = [
            "com.openai.chat",
            "com.openai.codex",
            "com.kagi.orion",
            "com.duckduckgo.macos.browser",
        ]

        for bundleID in aiAndBrowsers {
            XCTAssertEqual(
                AXWriteCapabilityStore.seedVerdict(bundleID: bundleID),
                .falseSuccess,
                "\(bundleID) must be seeded as .falseSuccess"
            )
            XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: bundleID))
        }
    }

    func testIDEBundleIDRecognition() {
        let checker = AXContextChecker()
        let ides = [
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
            "com.visualstudio.code",
            "com.apple.dt.Xcode",
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.google.android.studio",
            "dev.zed.Zed",
            "com.sublimetext.4",
            "com.panic.Nova",
            "org.rstudio.RStudio",
        ]

        for ide in ides {
            XCTAssertTrue(checker.isIDEBundleID(ide), "\(ide) must be recognized as an IDE")
        }

        // Dedicated terminals must NOT be classified as IDEs
        XCTAssertFalse(checker.isIDEBundleID("com.apple.Terminal"))
        XCTAssertFalse(checker.isIDEBundleID("com.googlecode.iterm2"))
        XCTAssertFalse(checker.isIDEBundleID("com.mitchellh.ghostty"))
    }

    func testPersistenceRoundTripWithOfficeVerdicts() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test-ax-write-capability.json")
        let store1 = AXWriteCapabilityStore(fileURL: fileURL)

        XCTAssertEqual(store1.verdict(for: "com.microsoft.Word", role: "AXTextArea"), .falseSuccess)

        // Condemn another app and verify persistence
        store1.recordFalseSuccess(bundleID: "com.example.customeditor", role: "AXTextArea")
        store1.recordDeliveryConfirmed(bundleID: "com.apple.TextEdit", role: "AXTextArea")

        let exp = expectation(description: "Persisted to disk")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let store2 = AXWriteCapabilityStore(fileURL: fileURL)
            XCTAssertEqual(store2.verdict(for: "com.microsoft.Word", role: "AXTextArea"), .falseSuccess)
            XCTAssertEqual(store2.verdict(for: "com.example.customeditor", role: "AXTextArea"), .falseSuccess)
            XCTAssertTrue(store2.hasProvenDeliveryReads(bundleID: "com.apple.TextEdit", role: "AXTextArea"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
}
