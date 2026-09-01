import XCTest
@testable import ExpanderEngine

/// `saveSnippets` reports its outcome, like `saveGroups` and `importGroups` already did.
///
/// It used to return `Void` and drop the `SaveOutcome` from `saveGroupsSerialized` on the floor
/// — the compiler flagged it as an unused result on every clean build. The failure was still
/// logged, so this was never silent, but a caller that wanted to react to a save that did not
/// land had no way to find out. These tests would not compile against the old signature.
final class SaveSnippetsOutcomeTests: XCTestCase {

    private func makeStore() -> (SnippetStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSaveOutcomeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = SnippetStore(
            location: SnippetStore.Location(fileURL: url, expectsExistingLibrary: false),
            watcherFactory: { _ in nil }
        )
        return (store, url)
    }

    func testASuccessfulSaveReportsThatItSaved() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let outcome = store.saveSnippets([
            SnippetModel(title: "Signature", triggerKeyword: ":sig", replacementText: "Regards")
        ])
        XCTAssertEqual(outcome, .saved)
        XCTAssertTrue(outcome.didSave)
    }

    /// The outcome must describe the save that just happened, not a cached verdict.
    func testTheOutcomeIsReportedForEverySaveNotJustTheFirst() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 0..<3 {
            let outcome = store.saveSnippets([
                SnippetModel(title: "S\(index)", triggerKeyword: ":s\(index)", replacementText: "v")
            ])
            XCTAssertEqual(outcome, .saved, "save \(index) should report its own outcome")
        }
    }

    /// The result stays discardable: the point was to make the outcome *available*, not to force
    /// every existing call site to handle something it cannot act on.
    func testTheResultRemainsDiscardable() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.saveSnippets([SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "v")])
        XCTAssertEqual(store.loadGroups().flatMap(\.snippets).count, 1)
    }

    /// The save actually round-trips — an outcome of `.saved` that did not persist would be
    /// worse than the missing return value it replaced.
    func testASavedOutcomeMeansTheSnippetIsReadableBack() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let outcome = store.saveSnippets([
            SnippetModel(title: "Signature", triggerKeyword: ":sig", replacementText: "Regards")
        ])
        XCTAssertTrue(outcome.didSave)
        XCTAssertEqual(store.loadGroups().flatMap(\.snippets).first?.triggerKeyword, ":sig")
    }
}
