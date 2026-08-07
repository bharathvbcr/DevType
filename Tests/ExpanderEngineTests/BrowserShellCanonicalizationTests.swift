import XCTest
@testable import ExpanderEngine

/// Chromium "installed web app" shells (PWAs / app shortcuts) get a fresh bundle ID per install
/// — `<browser>.app.<32 chars of a-p>` — so every capability decision used to treat them as
/// unknown, AX-trustworthy apps. The field incident this guards: the GitHub app installed from
/// Chrome (`com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg`) held a debounced match,
/// attempted the AX write, could not verify the field afterwards, and refused the expansion —
/// on every attempt, in every newly installed web app, forever.
///
/// The fix is identity, not lists: canonicalize the shell to its host browser for every verdict
/// read and write. One verdict then covers the browser and all of its web apps, past and future.
final class BrowserShellCanonicalizationTests: XCTestCase {

    /// The exact bundle ID from the field diagnostic report.
    private let chromeGitHubPWA = "com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg"

    // MARK: - Canonical form

    func testChromiumWebAppCollapsesToItsHostBrowser() {
        XCTAssertEqual(
            AXWriteCapabilityStore.canonicalBundleID(chromeGitHubPWA),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            AXWriteCapabilityStore.canonicalBundleID(
                "com.microsoft.edgemac.app.abcdefghijklmnopabcdefghijklmnop"
            ),
            "com.microsoft.edgemac"
        )
        XCTAssertEqual(
            AXWriteCapabilityStore.canonicalBundleID(
                "com.brave.Browser.app.ppppppppppppppppaaaaaaaaaaaaaaaa"
            ),
            "com.brave.Browser"
        )
    }

    /// Safari web apps ("Add to Dock") are the same WebKit view as Safari itself and must
    /// inherit Safari's seeded verdict — their bundle IDs carry a UUID, not a Chromium ID.
    func testSafariWebAppCollapsesToSafari() {
        let webApp = "com.apple.Safari.WebApp.6E4B1A2C-9F3D-4E5A-8B7C-0D1E2F3A4B5C"
        XCTAssertEqual(AXWriteCapabilityStore.canonicalBundleID(webApp), "com.apple.Safari")
        XCTAssertEqual(AXWriteCapabilityStore().verdict(for: webApp), .falseSuccess)
        // Not a UUID → not a Safari web app → identity preserved.
        XCTAssertEqual(
            AXWriteCapabilityStore.canonicalBundleID("com.apple.Safari.WebApp.helper"),
            "com.apple.Safari.WebApp.helper"
        )
    }

    /// The suffix must be exactly Chromium's extension-ID shape — 32 characters of `a`–`p` —
    /// so an ordinary reverse-DNS bundle ID that merely contains ".app." is never rewritten.
    func testOrdinaryBundleIDsAreNeverRewritten() {
        for bundleID in [
            "com.apple.TextEdit",
            "com.example.app",                                        // ends at ".app", no id
            "com.example.app.Main",                                   // wrong length + case
            "com.foo.app.tooshort",                                   // wrong length
            "com.foo.app.abcdefghijklmnopabcdefghijklmnoX",           // 32 chars, bad alphabet
            "com.foo.app.ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP",           // uppercase
            "com.foo.app.qrstuvwxyzqrstuvqrstuvwxyzqrstuv",           // outside a-p
            ".app.abcdefghijklmnopabcdefghijklmnop"                   // no host prefix
        ] {
            XCTAssertEqual(
                AXWriteCapabilityStore.canonicalBundleID(bundleID),
                bundleID,
                "\(bundleID) is not a Chromium web-app shell and must keep its identity."
            )
        }
    }

    // MARK: - Verdicts flow through the canonical identity

    /// The incident: the PWA must inherit Chrome's seeded false-success verdict, so the AX
    /// write is skipped and the expansion takes the proven HID paste path.
    func testWebAppInheritsTheHostBrowserSeed() {
        let store = AXWriteCapabilityStore()
        XCTAssertEqual(store.verdict(for: chromeGitHubPWA), .falseSuccess)
        XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: chromeGitHubPWA))
        XCTAssertFalse(
            store.canConfirmDelivery(bundleID: chromeGitHubPWA),
            "A PWA's AX cannot confirm delivery any more than its host browser's can — trusting"
                + " it is the re-paste/double-inject shape."
        )
    }

    /// A lesson learned in one web app must cover the host browser and every sibling shell.
    func testVerdictLearnedInOneWebAppCoversTheWholeFamily() {
        let store = AXWriteCapabilityStore()
        // An unknown (non-seeded) browser family, so the verdict can only come from learning.
        let host = "org.niche.Browser"
        let pwaA = "org.niche.Browser.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pwaB = "org.niche.Browser.app.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        XCTAssertEqual(store.verdict(for: pwaB), .unknown)

        store.recordFalseSuccess(bundleID: pwaA)

        XCTAssertEqual(store.verdict(for: host), .falseSuccess)
        XCTAssertEqual(store.verdict(for: pwaB), .falseSuccess)
    }

    /// Verdicts persisted before canonicalization existed live under the raw web-app bundle ID.
    /// They must still be honored, or an existing install re-pays the destructive first attempt.
    func testLegacyRawKeyVerdictsAreStillRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent(AXWriteCapabilityStore.persistenceFileName)

        let legacyPWA = "org.legacy.Browser.app.cccccccccccccccccccccccccccccccc"
        let legacy = """
        {"version":1,"entries":{"\(legacyPWA)":"falseSuccess"}}
        """
        try legacy.data(using: .utf8)!.write(to: fileURL)

        let store = AXWriteCapabilityStore(fileURL: fileURL)
        XCTAssertEqual(store.verdict(for: legacyPWA), .falseSuccess)
    }

    /// Role-scoped verdicts canonicalize the same way as bundle-only ones.
    func testRoleScopedLearningCanonicalizes() {
        let store = AXWriteCapabilityStore()
        let pwa = "org.niche.Browser.app.dddddddddddddddddddddddddddddddd"
        store.recordFalseSuccess(bundleID: pwa, role: "AXTextArea")
        XCTAssertTrue(
            store.shouldSkipAXSelectedText(bundleID: "org.niche.Browser", role: "AXTextArea")
        )
        XCTAssertFalse(
            store.shouldSkipAXSelectedText(bundleID: "org.niche.Browser", role: "AXTextField"),
            "§3.3 role scoping must survive canonicalization — a web view's verdict must not"
                + " condemn native fields."
        )
    }

    // MARK: - Escalating self-heal for unverifiable-after-write refusals

    /// One unverifiable-after-write observation must NOT condemn: a transient (focus stolen
    /// mid-inject, an AX tree caught mid-teardown) is indistinguishable from a broken shell on
    /// a single strike, and a wrong condemnation is effectively permanent because AX writes stop
    /// being attempted. The second strike condemns — a genuinely broken shell hits it on the
    /// user's very next retry.
    func testUnverifiableStrikesEscalateToACondemnation() {
        let store = AXWriteCapabilityStore()
        let shell = "org.unknown.Shell"

        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: shell, role: nil),
            .struck(count: 1)
        )
        XCTAssertEqual(
            store.verdict(for: shell), .unknown,
            "A single strike must leave the app untouched — it may have been a transient."
        )

        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: shell, role: nil),
            .condemned
        )
        XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: shell))
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: shell, role: nil),
            .alreadyCondemned
        )
    }

    /// Strikes accumulate under the canonical identity, so two web apps of one unknown browser
    /// pool their evidence instead of each needing two failures of its own.
    func testStrikesPoolAcrossAWebAppFamily() {
        let store = AXWriteCapabilityStore()
        let pwaA = "org.niche.Browser.app.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        let pwaB = "org.niche.Browser.app.ffffffffffffffffffffffffffffffff"

        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: pwaA, role: nil),
            .struck(count: 1)
        )
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: pwaB, role: nil),
            .condemned,
            "The sibling web app is the same renderer — its strike is the family's second."
        )
        XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: "org.niche.Browser"))
    }

    /// A strike already covered by a condemnation (seeded or learned) reports as such and does
    /// not double-log or churn the persistence.
    func testStrikeAgainstASeededAppReportsAlreadyCondemned() {
        let store = AXWriteCapabilityStore()
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: chromeGitHubPWA, role: nil),
            .alreadyCondemned,
            "The PWA inherits Chrome's seed — the write should never have been attempted, and"
                + " a stray strike must not relearn what is already known."
        )
    }

    // MARK: - The debounce hold is universal, the write path is identity-aware

    /// Holding is universal — web-app shells included. What canonicalization governs is the
    /// *write path* at fire time: these shells skip the doomed AX write and deliver via HID
    /// paste, so the held expansion succeeds instead of refusing as unverifiable.
    func testWebAppShellsHoldAndSkipTheAXWrite() {
        for bundleID in [
            chromeGitHubPWA,
            "com.microsoft.edgemac.app.abcdefghijklmnopabcdefghijklmnop",
            "com.brave.Browser.app.ppppppppppppppppaaaaaaaaaaaaaaaa",
            "com.vivaldi.Vivaldi.app.abcdefghijklmnopabcdefghijklmnop",
            "com.operasoftware.Opera.app.abcdefghijklmnopabcdefghijklmnop"
        ] {
            XCTAssertTrue(
                EventTapEngine.canHoldMatch(bundleID: bundleID),
                "\(bundleID): debounce must be universal — web-app shells included."
            )
            XCTAssertTrue(
                AXWriteCapabilityStore().shouldSkipAXSelectedText(bundleID: bundleID),
                "\(bundleID): the fire-time write must skip AX and paste via HID, or the"
                    + " expansion refuses as unverifiable."
            )
        }
    }
}
