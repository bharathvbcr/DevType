import Foundation
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

final class SnippetImportFlowPlanTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testConfirmationCommitsThePreparedPlanWithoutReReadingTheSourceURL() throws {
        let sourceURL = Self.repositoryRoot
            .appendingPathComponent("Sources/DevTypeAppCore/SnippetImportFlow.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("SnippetImporter.prepareImport(from: url)"))
        XCTAssertTrue(source.contains("store.commitImport(preview.plan, mode: mode)"))
        XCTAssertFalse(
            source.contains("store.importSnippets(from: url, mode: mode)"),
            "The confirmation callback must commit the already-previewed value plan, never re-read its URL."
        )
    }

    func testSlowImportPhasesAreVisibleAndFailuresAreNotRawFrameworkProse() throws {
        let sourceURL = Self.repositoryRoot
            .appendingPathComponent("Sources/DevTypeAppCore/SnippetImportFlow.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DevTypeProgressPresentation.present("))
        XCTAssertTrue(source.contains("alert.import.progress.parsing.title"))
        XCTAssertTrue(source.contains("alert.import.progress.committing.title"))
        XCTAssertFalse(
            source.contains("message: error.localizedDescription"),
            "Importer errors may contain a selected path, parser payload, or other private detail."
        )
        XCTAssertFalse(
            source.contains("body += \"\\n\" + result.sourcePath"),
            "The result alert should not echo an absolute user-selected path."
        )
    }

    func testARefusedImportSaveCannotUseTheSuccessPresentation() throws {
        let sourceURL = Self.repositoryRoot
            .appendingPathComponent("Sources/DevTypeAppCore/SnippetImportFlow.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("guard summary.outcome.didSave else"))
        XCTAssertTrue(source.contains("alert.import.saveFailed.title"))
        XCTAssertTrue(source.contains("ActivityHistoryStore.publish(.importFailed)"))
    }

    func testImportFailureMessagesDiscardPathsAndParserPayloads() {
        let loc = LocalizationManager()
        let privateDetail = "/Users/private/Library/token-secret malformed: bearer-value"
        let failures: [Error] = [
            SnippetImporter.ImportError.pathNotFound(privateDetail),
            SnippetImporter.ImportError.unrecognizedSource(privateDetail),
            SnippetImporter.ImportError.noImportableSnippets(privateDetail),
            SnippetImporter.ImportError.resourceLimitExceeded(.fileCount),
            SnippetImporter.ImportError.resourceLimitExceeded(.aggregateBytes),
            SnippetImporter.ImportError.resourceLimitExceeded(.snippetCount),
            SnippetImporter.ImportError.attachmentCommitFailed,
            SnippetImporter.ImportError.libraryCommitFailed,
            TEImporter.ImportError.folderNotFound(privateDetail),
            TEImporter.ImportError.noGroupFiles(privateDetail),
            EspansoImporter.ImportError.pathNotFound(privateDetail),
            EspansoImporter.ImportError.noMatchFiles(privateDetail),
            EspansoImporter.ImportError.parseFailed(privateDetail, privateDetail),
            CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: privateDetail])
        ]

        for failure in failures {
            let message = SnippetImportFlow.failureMessage(for: failure, loc: loc)
            XCTAssertFalse(message.contains(privateDetail), "Private import detail leaked: \(message)")
            XCTAssertFalse(message.contains("/Users/private"), "Private import path leaked: \(message)")
            XCTAssertNotEqual(message, failure.localizedDescription)
            XCTAssertGreaterThan(message.count, 20, "Failure guidance should remain actionable.")
        }
    }

    func testImportSaveFailureMessagesDiscardStoreFailureProse() {
        let loc = LocalizationManager()
        let privateDetail = "/Users/private/snippets.json token-secret"
        let message = SnippetImportFlow.saveFailureMessage(
            for: .failed(privateDetail),
            loc: loc
        )

        XCTAssertFalse(message.contains(privateDetail))
        XCTAssertFalse(message.contains("/Users/private"))
        XCTAssertGreaterThan(message.count, 20)
    }

    func testStructuredImportDetailsAreLocalizedForDowngradesImagesSkipsAndScoping() {
        let savedLanguage = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
        defer {
            if let savedLanguage {
                UserDefaults.standard.set(savedLanguage, forKey: LocalizationManager.deviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
            }
        }

        let notes: [SnippetImporter.ImportNote] = [
            .richTextDowngraded(2),
            .scriptImportedLiterally(3),
            .imageMatchImported(4),
            .imageMatchSkipped(5),
            .appScopePreserved(6),
            .unsupportedMatchSkipped(7)
        ]
        var renderedByLanguage: [AppLanguage: [String]] = [:]

        for language in AppLanguage.concreteCases {
            let loc = LocalizationManager()
            loc.language = language
            let rendered = notes.map { SnippetImportFlow.localizedNote($0, loc: loc) }
            renderedByLanguage[language] = rendered

            XCTAssertEqual(rendered.count, notes.count)
            XCTAssertTrue(rendered[0].contains("2"))
            XCTAssertTrue(rendered[1].contains("3"))
            XCTAssertTrue(rendered[2].contains("4"))
            XCTAssertTrue(rendered[3].contains("5"))
            XCTAssertTrue(rendered[4].contains("6"))
            XCTAssertTrue(rendered[5].contains("7"))
            XCTAssertFalse(rendered.joined().contains("alert.import.note"))
        }

        XCTAssertNotEqual(renderedByLanguage[.en], renderedByLanguage[.ko])
        XCTAssertNotEqual(renderedByLanguage[.en], renderedByLanguage[.ja])
        XCTAssertNotEqual(renderedByLanguage[.ko], renderedByLanguage[.ja])
    }

    func testPreviewSheetRendersCountsAndRowsFromTheSamePreparedPlanProjection() throws {
        let sourceURL = Self.repositoryRoot
            .appendingPathComponent("Sources/DevTypeAppCore/SnippetImportPreviewSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("preview: SnippetStore.ImportPreview"))
        XCTAssertTrue(source.contains("preview.plan.snippetCount"))
        XCTAssertTrue(source.contains("preview.items"))
        XCTAssertFalse(
            source.contains("private func buildPreviewItems()"),
            "The UI must not maintain a second trigger-collision implementation."
        )
    }

    func testTagSuggestionsMergeOntoLatestLibraryWithoutRevertingConcurrentEdits() {
        let targetID = UUID()
        let groupID = UUID()
        let target = SnippetModel(
            id: targetID,
            title: "Deployment guide",
            triggerKeyword: ":deploy",
            replacementText: String(repeating: "deployment body ", count: 8)
        )
        let baseline = [SnippetGroup(id: groupID, name: "Work", snippets: [target])]
        var tagged = baseline
        tagged[0].snippets[0].tags = ["deployment", "guide"]
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)

        var latest = baseline
        latest[0].snippets[0].enabled = false
        latest[0].snippets.append(SnippetModel(
            title: "Concurrent",
            triggerKeyword: ":concurrent",
            replacementText: "must survive"
        ))
        let summary = merge.apply(to: &latest)

        XCTAssertEqual(summary, .init(applied: 1, stale: 0))
        XCTAssertFalse(latest[0].snippets[0].enabled)
        XCTAssertEqual(latest[0].snippets[0].tags, ["deployment", "guide"])
        XCTAssertNotNil(latest[0].snippets.first(where: { $0.triggerKeyword == ":concurrent" }))
    }

    func testTagSuggestionsRefuseChangedMovedDeletedAndDuplicateTargets() {
        let targetID = UUID()
        let originalGroupID = UUID()
        let target = SnippetModel(
            id: targetID,
            title: "Deployment guide",
            triggerKeyword: ":deploy",
            replacementText: String(repeating: "deployment body ", count: 8)
        )
        let baseline = [SnippetGroup(id: originalGroupID, name: "Work", snippets: [target])]
        var tagged = baseline
        tagged[0].snippets[0].tags = ["deployment"]
        let merge = SnippetTagSuggestionMerge(baseline: baseline, tagged: tagged)

        var changedBody = baseline
        changedBody[0].snippets[0].replacementText = "new body"
        XCTAssertEqual(merge.apply(to: &changedBody), .init(applied: 0, stale: 1))
        XCTAssertTrue(changedBody[0].snippets[0].tags.isEmpty)

        var moved = [SnippetGroup(id: UUID(), name: "Other", snippets: [target])]
        XCTAssertEqual(merge.apply(to: &moved), .init(applied: 0, stale: 1))

        var deleted = [SnippetGroup(id: originalGroupID, name: "Work")]
        XCTAssertEqual(merge.apply(to: &deleted), .init(applied: 0, stale: 1))

        var duplicated = baseline
        duplicated[0].snippets.append(target)
        XCTAssertEqual(merge.apply(to: &duplicated), .init(applied: 0, stale: 1))
        XCTAssertTrue(duplicated[0].snippets.allSatisfy(\.tags.isEmpty))
    }
}

final class SnippetOperationGateTests: XCTestCase {
    func testGateAdmitsExactlyOneConcurrentOperationAndReopensAfterFinish() {
        let gate = SnippetOperationGate()
        let resultLock = NSLock()
        var admitted = 0

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if gate.begin() {
                resultLock.lock()
                admitted += 1
                resultLock.unlock()
            }
        }

        XCTAssertEqual(admitted, 1)
        XCTAssertTrue(gate.isActive)
        gate.finish()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
        gate.finish()
    }
}

@MainActor
final class SnippetOperationProgressPresentationTests: XCTestCase {
    func testProgressPresentationIsVisibleUntilExplicitlyDismissed() {
        _ = NSApplication.shared
        let presentation = DevTypeProgressPresentation.present(
            title: "Preparing Import",
            message: "Reading and checking the selected snippet library.",
            window: nil
        )

        XCTAssertTrue(presentation.isVisible)
        presentation.dismiss()
        XCTAssertFalse(presentation.isVisible)
    }

    func testProgressPresentationUsesAndReleasesTheProvidedSheetHost() {
        _ = NSApplication.shared
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let presentation = DevTypeProgressPresentation.present(
            title: "Exporting Snippets",
            message: "Preparing and saving DevType JSON.",
            window: host
        )

        XCTAssertNotNil(host.attachedSheet)
        XCTAssertTrue(presentation.isVisible)
        presentation.dismiss()
        XCTAssertNil(host.attachedSheet)
        XCTAssertFalse(presentation.isVisible)
    }
}
