import XCTest
@testable import ExpanderEngine

/// A `falseSuccess` verdict is a claim about a specific build of someone else's code, and it was
/// permanent. The store's own escape hatch — `trustedStreak` rehabilitating after verified AX
/// writes — is unreachable by construction: a condemned app is never given an AX write to
/// verify, so the streak can never start.
///
/// The cost is visible in the field: 11 of 16 apps condemned, every expansion into them pasting
/// via the clipboard, each one reported `postedUnverified` and each one holding the payload on
/// the general pasteboard waiting for evidence that can never arrive.
///
/// An app *update* is the one event that plausibly changes the answer. These tests pin the door
/// open exactly that far — and no further.
final class AXCondemnationLifecycleTests: XCTestCase {

    private let shell = "org.example.ElectronShell"
    private let role = "AXTextArea"

    /// A resolver standing in for the installed app's build.
    private final class Builds {
        var value: String?
        init(_ value: String?) { self.value = value }
        var resolver: (String) -> String? { { [weak self] _ in self?.value } }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ax-condemnation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(builds: Builds, file: String = "caps.json") -> AXWriteCapabilityStore {
        AXWriteCapabilityStore(
            fileURL: directory.appendingPathComponent(file),
            currentBuild: builds.resolver
        )
    }

    // MARK: - The door opens exactly one build's worth

    func testCondemnationIsRetiredWhenTheAppIsUpdated() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordFalseSuccess(bundleID: shell, role: role)
        XCTAssertEqual(store.verdict(for: shell, role: role), .falseSuccess)

        builds.value = "1.1-140" // the user updates the app
        XCTAssertEqual(
            store.verdict(for: shell, role: role), .unknown,
            "A verdict earned by a different build must not be inherited — AX gets one re-test."
        )
        // And it stays retired rather than flapping back on the next query.
        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)
        XCTAssertTrue(store.canConfirmDelivery(bundleID: shell, role: role))
    }

    func testAnUnchangedAppStaysCondemned() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordFalseSuccess(bundleID: shell, role: role)

        for _ in 0..<5 {
            XCTAssertEqual(
                store.verdict(for: shell, role: role), .falseSuccess,
                "Nothing about the app changed; re-probing it would just re-learn the same lie."
            )
        }
    }

    /// Absence of evidence is not evidence of change: a verdict with no stamp (an older build's
    /// file, or an app whose bundle could not be located) keeps today's permanent behaviour.
    func testACondemnationWithNoStampIsNeverRetired() {
        let unresolvable = Builds(nil)
        let store = makeStore(builds: unresolvable)
        store.recordFalseSuccess(bundleID: shell, role: role)
        XCTAssertEqual(store.verdict(for: shell, role: role), .falseSuccess)

        // The app becomes locatable later — still no stamp to compare against, so no retirement.
        unresolvable.value = "2.0-200"
        XCTAssertEqual(
            store.verdict(for: shell, role: role), .falseSuccess,
            "Without a recorded build there is nothing to say the app changed."
        )
    }

    /// Retirement must clear the *other* trust dimension too: a new build's AX reads are as
    /// unproven as its writes, and stale proof re-arms corrective writes it cannot justify.
    func testRetirementAlsoRevokesDeliveryReadProof() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordDeliveryConfirmed(bundleID: shell, role: role)
        XCTAssertTrue(store.hasProvenDeliveryReads(bundleID: shell, role: role))
        store.recordFalseSuccess(bundleID: shell, role: role)
        XCTAssertFalse(store.hasProvenDeliveryReads(bundleID: shell, role: role))

        store.recordDeliveryConfirmed(bundleID: shell, role: role)
        builds.value = "1.1-140"
        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)
        XCTAssertFalse(
            store.hasProvenDeliveryReads(bundleID: shell, role: role),
            "A retired condemnation leaves an app unproven in both dimensions, not half-trusted."
        )
    }

    /// The end-to-end point: rehabilitation used to be unreachable. After a retirement the app
    /// is `unknown`, so AX is attempted again — and a verified write can finally be recorded.
    func testRehabilitationIsReachableOnceTheDoorOpens() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordFalseSuccess(bundleID: shell, role: role)
        builds.value = "2.0-200"

        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)
        store.recordTrusted(bundleID: shell, role: role)
        XCTAssertEqual(
            store.verdict(for: shell, role: role), .trusted,
            "With the condemnation retired, one verified write is enough — the streak counter"
                + " only exists to slow down resurrecting a *still-condemned* app."
        )
    }

    /// The re-test is one shot, not a fresh two-strike trial. Each strike costs the user a
    /// refused expansion, and an app with a prior conviction has not earned the benefit of the
    /// doubt that ladder was built to give first-contact apps.
    func testAStillBrokenAppReCondemnsOnTheFirstStrikeAfterRetirement() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordFalseSuccess(bundleID: shell, role: role)
        builds.value = "1.1-140"
        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)

        // The update did not fix it: the very next unverifiable write returns it to condemned.
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: shell, role: role), .condemned,
            "A re-tested app must not get a second free strike — that is two refused expansions."
        )
        XCTAssertEqual(store.verdict(for: shell, role: role), .falseSuccess)
        // And it is re-stamped against the new build, so the next update re-tests once more.
        builds.value = "1.2-180"
        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)
    }

    /// A never-seen app keeps the full ladder — the refinement above must not leak into it.
    func testAFirstContactAppStillGetsTheTwoStrikeLadder() {
        let store = makeStore(builds: Builds("1.0-100"))
        let fresh = "org.example.NeverSeen"
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: fresh, role: role), .struck(count: 1),
            "One transient must not condemn an app nobody has ever observed."
        )
        XCTAssertEqual(store.verdict(for: fresh, role: role), .unknown)
        XCTAssertEqual(store.recordUnverifiableAfterWrite(bundleID: fresh, role: role), .condemned)
    }

    /// `reset()` clears every other state map. Leaving the build stamps behind is how a field
    /// added later drifts out of sync with the state it annotates — the stamp would outlive the
    /// verdict it describes, and a later condemnation would briefly carry a build it never saw.
    func testResetClearsTheBuildStampsToo() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordFalseSuccess(bundleID: shell, role: role)
        store.reset()
        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)

        // Condemn again under a build that matches the *pre-reset* stamp. If the stale stamp
        // survived, the store now holds a stamp that no observation produced.
        builds.value = "1.0-100"
        store.recordFalseSuccess(bundleID: shell, role: role)
        XCTAssertEqual(store.verdict(for: shell, role: role), .falseSuccess)
        builds.value = "1.0-100"
        XCTAssertEqual(
            store.verdict(for: shell, role: role), .falseSuccess,
            "The stamp must describe the condemnation that actually happened."
        )
        builds.value = "2.0-200"
        XCTAssertEqual(store.verdict(for: shell, role: role), .unknown)
    }

    // MARK: - Persistence

    func testTheStampSurvivesARestartAndSoDoesTheRetirement() {
        let builds = Builds("1.0-100")
        let store = makeStore(builds: builds)
        store.recordFalseSuccess(bundleID: shell, role: role)
        // scheduleSave coalesces on a background queue; give it room to land.
        let saved = expectation(description: "verdict persisted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { saved.fulfill() }
        wait(for: [saved], timeout: 3)

        let reopened = makeStore(builds: builds)
        XCTAssertEqual(
            reopened.verdict(for: shell, role: role), .falseSuccess,
            "The condemnation must survive a restart, as it always has."
        )

        builds.value = "1.1-140"
        XCTAssertEqual(
            reopened.verdict(for: shell, role: role), .unknown,
            "And the stamp must have survived with it, or the update is invisible after a restart."
        )
    }

    /// A file written before stamps existed must load and behave exactly as it does today.
    func testALegacyFileWithoutStampsKeepsItsPermanentCondemnations() throws {
        let url = directory.appendingPathComponent("legacy.json")
        let legacy = #"{"version":1,"entries":{"org.example.ElectronShell|AXTextArea":"falseSuccess"}}"#
        try Data(legacy.utf8).write(to: url)

        let builds = Builds("9.9-999")
        let store = AXWriteCapabilityStore(fileURL: url, currentBuild: builds.resolver)
        XCTAssertEqual(
            store.verdict(for: shell, role: role), .falseSuccess,
            "An unstamped verdict has no build to compare against and must not be retired."
        )
    }
}

/// Adversarial pressure on the verdict store: hostile persisted files, namespace collisions,
/// and concurrent condemn/retire/query from many threads.
final class AXCapabilityStoreStressTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ax-caps-stress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The namespace rule the read-proof loader already documents ("namespaces must never eat
    /// each other's data"), applied to the build-stamp namespace: a *verdict* recorded for a
    /// pathological bundle ID starting with the stamp prefix must survive as a verdict.
    func testStampNamespaceCannotEatAVerdict() throws {
        let hostile = "condemnedBuild|org.example.Evil"
        let file = url("hostile.json")
        let json = """
        {"version":1,"entries":{"\(hostile)":"falseSuccess","deliveryRead|org.example.Ok":"confirmed"}}
        """
        try Data(json.utf8).write(to: file)

        let store = AXWriteCapabilityStore(fileURL: file, currentBuild: { _ in "9.9" })
        XCTAssertEqual(
            store.verdict(for: hostile), .falseSuccess,
            "A verdict whose key merely starts with the stamp prefix must not be read as a stamp."
        )
        XCTAssertTrue(store.hasProvenDeliveryReads(bundleID: "org.example.Ok", role: nil))
    }

    /// And the reverse direction: a stamp must never be written in a form that reads back as a
    /// verdict, even when the app's version string is adversarial.
    func testAVersionStringThatLooksLikeAVerdictIsNotPersisted() {
        let file = url("collide.json")
        let shell = "org.example.Shell"
        let store = AXWriteCapabilityStore(fileURL: file, currentBuild: { _ in "falseSuccess" })
        store.recordFalseSuccess(bundleID: shell, role: nil)

        let saved = expectation(description: "persisted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { saved.fulfill() }
        wait(for: [saved], timeout: 3)

        // Reopen with a *different* build. The stamp was dropped rather than corrupting the
        // namespace, so the app keeps the old permanent-condemnation behaviour — fail-safe.
        let reopened = AXWriteCapabilityStore(fileURL: file, currentBuild: { _ in "2.0" })
        XCTAssertEqual(reopened.verdict(for: shell), .falseSuccess)
        // Whatever landed on disk must still parse as exactly one verdict entry.
        if let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = object["entries"] as? [String: String] {
            XCTAssertEqual(entries[shell], "falseSuccess")
            for (key, raw) in entries where key.hasPrefix("condemnedBuild|") {
                XCTAssertNotEqual(raw, "falseSuccess", "a stamp must never be readable as a verdict")
                XCTAssertNotEqual(raw, "trusted")
            }
        }
    }

    func testHostilePersistedFilesNeverCrashOrLeakState() throws {
        let hostiles: [String] = [
            "",
            "not json at all",
            "{}",
            #"{"version":1}"#,
            #"{"version":1,"entries":{}}"#,
            #"{"version":999,"entries":{"a":"falseSuccess"}}"#,
            #"{"version":1,"entries":{"":"falseSuccess"}}"#,
            #"{"version":1,"entries":{"a":""}}"#,
            #"{"version":1,"entries":{"condemnedBuild|":"1.0"}}"#,
            #"{"version":1,"entries":{"deliveryRead|":"confirmed"}}"#,
            #"{"version":1,"entries":{"a":"nonsense-verdict"}}"#,
            #"{"version":-1,"entries":{"a":"trusted"}}"#,
        ]
        for (index, body) in hostiles.enumerated() {
            let file = url("hostile-\(index).json")
            try Data(body.utf8).write(to: file)
            let store = AXWriteCapabilityStore(fileURL: file, currentBuild: { _ in "1.0" })
            // Whatever it loaded, it must answer coherently and never resurrect a condemnation
            // for an app it has no verdict for.
            XCTAssertEqual(store.verdict(for: "org.example.Unrelated"), .unknown, "file #\(index)")
            XCTAssertTrue(store.canConfirmDelivery(bundleID: "org.example.Unrelated"), "file #\(index)")
        }
    }

    /// Concurrent condemn / retire / query. The retirement does a lock-drop-and-recheck around
    /// the build lookup, which is exactly where a race would live.
    func testConcurrentCondemnRetireAndQueryStayCoherent() {
        let builds = NSMutableString(string: "1.0")
        let buildsLock = NSLock()
        let store = AXWriteCapabilityStore(
            fileURL: nil,
            currentBuild: { _ in
                buildsLock.lock(); defer { buildsLock.unlock() }
                return String(builds)
            }
        )
        let apps = (0..<8).map { "org.example.App\($0)" }
        let group = DispatchGroup()

        for worker in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<400 {
                    let app = apps[(worker + i) % apps.count]
                    switch i % 4 {
                    case 0: store.recordFalseSuccess(bundleID: app, role: "AXTextArea")
                    case 1: _ = store.verdict(for: app, role: "AXTextArea")
                    case 2: _ = store.canConfirmDelivery(bundleID: app, role: "AXTextArea")
                    default:
                        buildsLock.lock()
                        builds.setString(String("v\(i % 7)"))
                        buildsLock.unlock()
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "deadlock under concurrent access")

        // Coherence: every app answers one of the three legal verdicts, and a condemned app is
        // never simultaneously reported as a confirmable delivery witness.
        for app in apps {
            let verdict = store.verdict(for: app, role: "AXTextArea")
            XCTAssertTrue([.unknown, .trusted, .falseSuccess].contains(verdict))
            if verdict == .falseSuccess {
                XCTAssertFalse(store.canConfirmDelivery(bundleID: app, role: "AXTextArea"))
                XCTAssertFalse(store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea"))
            }
        }
    }

    /// Retirement must not become an oscillator: a build that flaps must not let an app slip
    /// out of condemnation without ever being re-tested.
    func testFlappingBuildStringsCannotLaunderACondemnation() {
        var build = "1.0"
        let store = AXWriteCapabilityStore(fileURL: nil, currentBuild: { _ in build })
        let shell = "org.example.Flapper"
        store.recordFalseSuccess(bundleID: shell, role: nil)

        for round in 0..<25 {
            build = round.isMultiple(of: 2) ? "2.0" : "1.0"
            if store.verdict(for: shell) == .unknown {
                // Retired: the only way back to condemned is a fresh observation, exactly as a
                // never-seen app would be treated. Simulate the app still being broken.
                XCTAssertEqual(store.recordUnverifiableAfterWrite(bundleID: shell, role: nil), .condemned)
            }
            XCTAssertEqual(
                store.verdict(for: shell), .falseSuccess,
                "round \(round): a still-broken app must end every round condemned"
            )
        }
    }
}
