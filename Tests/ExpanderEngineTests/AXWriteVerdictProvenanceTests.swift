import XCTest
@testable import ExpanderEngine

/// `AXWriteCapabilityStore` produces `.falseSuccess` from two completely different sources:
///
///  1. `recordFalseSuccess` / `recordTrusted` — DevType attempted an AX write in that app and
///     checked the field afterwards. That is a measurement.
///  2. `seedVerdict` and `isAXWriteUnstableRole` — a built-in table matched the bundle ID or the
///     focused role. Nothing was measured; the app may never have been expanded into at all.
///
/// Both skip the AX write, so they look identical in behaviour and identical in a log line. They
/// are not identical evidence: when the diagnostic report is used to debug a delivery failure,
/// "DevType watched this app lie" and "DevType shipped with this app on a prefix list" lead to
/// different next steps. These tests pin the report's separation of the two.
final class AXWriteVerdictProvenanceTests: XCTestCase {

    /// Seeds spanning every shape of the table: an exact bundle match, a `com.todesktop.` prefix,
    /// a Mozilla prefix, a Microsoft prefix, and an installed web app that canonicalizes onto a
    /// seeded host browser.
    private let seededOnly = [
        "com.anthropic.claudefordesktop",
        "com.todesktop.230313mzl4w4u92",
        "org.mozilla.firefox",
        "com.microsoft.Word",
        "com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg"
    ]

    private func gate() -> DiagnosticReport.ExpandGateSnapshot {
        DiagnosticReport.ExpandGateSnapshot(
            canUseAX: true,
            axTrusted: true,
            focusedAvailable: true,
            isSecureField: false,
            hasIMEMarkedText: false,
            shouldBlockExpand: false,
            blockReason: "ok"
        )
    }

    private func header(
        store: AXWriteCapabilityStore,
        frontmostBundleID: String?
    ) -> String {
        let projection = DiagnosticReport.captureAXWriteVerdictProjection(store: store)
        var context = DiagnosticReport.Context(
            bundleID: "com.devtype.app",
            appPath: "/Applications/DevType.app",
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: nil,
            designatedRequirement: nil,
            snapshot: PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true),
            tapRunning: true,
            engineEnabled: true,
            secureInputActive: false,
            displayStatus: "Status: Active",
            lastInjectOutcome: nil,
            frontmostAppName: nil,
            frontmostBundleID: frontmostBundleID,
            frontmostPID: nil,
            mutedApps: [],
            expandGate: gate(),
            siblingPaths: [],
            macOSVersion: "15.0",
            appVersion: "1.0.0",
            axWriteSeedLines: DiagnosticReport.captureAXWriteSeedLines(
                frontmostBundleID: frontmostBundleID,
                store: store
            )
        )
        context.axWriteVerdictProjection = projection
        return DiagnosticReport.formatHeader(context)
    }

    /// Lines of the rendered report that name this identifier. Scoped deliberately: the section's
    /// own projection summary carries an `observed=N` count that is about bounding, not about
    /// provenance, and it never names an app.
    private func lines(naming identifier: String, in header: String) -> [String] {
        header.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains(identifier) }
    }

    // MARK: - A seed must never be readable as an observation

    func testPurelySeededBundleIDNeverRendersAsAnObservedVerdict() {
        let store = AXWriteCapabilityStore()

        for bundleID in seededOnly {
            XCTAssertEqual(
                store.verdict(for: bundleID, role: nil), .falseSuccess,
                "\(bundleID) is expected to be seeded — the test is meaningless otherwise."
            )
            XCTAssertNil(
                store.observedVerdict(bundleID: bundleID, role: nil),
                "\(bundleID) was never written to, so nothing was observed about it."
            )

            let rendered = header(store: store, frontmostBundleID: bundleID)
            let canonical = AXWriteCapabilityStore.canonicalBundleID(bundleID)
            let naming = lines(naming: canonical, in: rendered)

            XCTAssertFalse(naming.isEmpty, "The report must say something about \(canonical).")
            for line in naming {
                XCTAssertFalse(
                    line.contains("observed"),
                    "A seeded default rendered as an observation: \(line)"
                )
            }
            XCTAssertTrue(
                naming.contains { $0.contains("falseSuccess (seeded") },
                "\(canonical) must be marked seeded: \(naming)"
            )
            XCTAssertTrue(
                rendered.contains("-- Built-in AX write defaults (seeded — never observed) --"),
                rendered
            )
            XCTAssertTrue(rendered.contains("(none learned yet"), rendered)
        }
    }

    /// The role prior is the other seeded source, and no per-app row can express it: it condemns
    /// every app. It must not create a learned entry either.
    func testUnstableRoleSeedIsNeverRecordedAsAnObservation() {
        let store = AXWriteCapabilityStore()
        let nativeApp = "com.example.NativeApp"

        XCTAssertEqual(store.verdict(for: nativeApp, role: "AXComboBox"), .falseSuccess)
        XCTAssertNil(store.observedVerdict(bundleID: nativeApp, role: "AXComboBox"))
        XCTAssertEqual(
            DiagnosticReport.captureAXWriteVerdictProjection(store: store).observedCount, 0,
            "Consulting a role prior must not learn anything."
        )

        let rendered = header(store: store, frontmostBundleID: nativeApp)
        XCTAssertTrue(
            rendered.contains("Seeded falseSuccess in any app when the focused AX role is: AXComboBox"),
            rendered
        )
    }

    // MARK: - A measurement must still read as one

    func testObservedVerdictRendersWithTheObservedMarker() {
        let store = AXWriteCapabilityStore()
        let shell = "com.example.Shell"
        store.recordFalseSuccess(bundleID: shell, role: nil)

        XCTAssertEqual(store.observedVerdict(bundleID: shell, role: nil), .falseSuccess)

        let rendered = header(store: store, frontmostBundleID: shell)
        let naming = lines(naming: shell, in: rendered)

        XCTAssertTrue(
            naming.contains { $0.contains("falseSuccess (observed — AX lied here, pasting instead)") },
            "\(naming)"
        )
        XCTAssertFalse(
            naming.contains { $0.contains("(seeded") },
            "A measured verdict must not be attributed to a built-in default: \(naming)"
        )
    }

    /// The case that proves the two sources are actually distinguished rather than merely worded
    /// differently: a *seeded* app whose real behaviour was later measured to be the opposite.
    /// The seed says falseSuccess; the observation says trusted; the report must report the
    /// observation, and must not also claim the app is running on a default.
    func testObservationOnASeededBundleOverridesAndOutranksTheSeedInTheReport() {
        let store = AXWriteCapabilityStore()
        let chrome = "com.google.Chrome"
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: chrome, role: nil), .falseSuccess)

        for _ in 0..<AXWriteCapabilityStore.trustedStreakToRehabilitate {
            store.recordTrusted(bundleID: chrome, role: nil)
        }
        XCTAssertEqual(store.verdict(for: chrome, role: nil), .trusted)

        let rendered = header(store: store, frontmostBundleID: chrome)
        let naming = lines(naming: chrome, in: rendered)

        XCTAssertTrue(
            naming.contains { $0.contains("trusted (observed — AX writes verified here)") },
            "\(naming)"
        )
        XCTAssertTrue(
            naming.contains { $0.contains("not a default — trusted was observed here") },
            "\(naming)"
        )
        XCTAssertFalse(naming.contains { $0.contains("(seeded") }, "\(naming)")
    }

    /// An app with neither a seed nor an observation must say so, rather than being silently
    /// absent — "nothing here" is itself the answer to "why did AX get tried in this app?".
    func testUnseededUnobservedAppIsReportedAsHavingNoVerdictAtAll() {
        let store = AXWriteCapabilityStore()
        let plain = "com.example.PlainCocoaApp"
        XCTAssertEqual(store.verdict(for: plain, role: nil), .unknown)

        let rendered = header(store: store, frontmostBundleID: plain)
        XCTAssertTrue(
            lines(naming: plain, in: rendered).contains {
                $0.contains("none — no seed and nothing observed; AX will be tried and verified")
            },
            rendered
        )
    }

    /// An installed web app answers to its host browser's verdict. The report must name the
    /// collapse, or the seeded row refers to an app the rest of the report never mentions.
    func testInstalledWebAppReportsTheHostBrowserItResolvesTo() {
        let store = AXWriteCapabilityStore()
        let webApp = "com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg"

        let rendered = header(store: store, frontmostBundleID: webApp)
        XCTAssertTrue(
            rendered.contains("Frontmost resolves to com.google.Chrome (installed web app → host browser)"),
            rendered
        )
    }

    // MARK: - Reading the report must not change what the next expansion does

    func testCapturingSeedLinesNeverRetiresACondemnationTheWayALiveLookupWould() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ax-provenance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        final class Builds {
            var value: String?
            init(_ value: String?) { self.value = value }
            var resolver: (String) -> String? { { [weak self] _ in self?.value } }
        }

        let builds = Builds("1.0-100")
        let store = AXWriteCapabilityStore(
            fileURL: directory.appendingPathComponent("caps.json"),
            currentBuild: builds.resolver
        )
        let shell = "org.example.ElectronShell"
        store.recordFalseSuccess(bundleID: shell, role: nil)
        builds.value = "1.1-140" // the user updates the app

        _ = DiagnosticReport.captureAXWriteSeedLines(frontmostBundleID: shell, store: store)
        XCTAssertEqual(
            store.observedVerdict(bundleID: shell, role: nil), .falseSuccess,
            "Generating a report must not retire a condemnation."
        )
        XCTAssertEqual(
            store.verdict(for: shell, role: nil), .falseSuccess,
            "A verdict query is also a read — only the AX-write seam may spend the re-test."
        )
        XCTAssertFalse(
            store.shouldSkipAXSelectedText(bundleID: shell, role: nil),
            "The live write path still retires it — the report is what must stay read-only."
        )
        XCTAssertNil(store.observedVerdict(bundleID: shell, role: nil))
    }
}
