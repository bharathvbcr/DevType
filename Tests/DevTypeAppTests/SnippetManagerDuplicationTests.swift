import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class SnippetManagerDuplicationTests: XCTestCase {
    private let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let duplicateDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func fullyPopulatedSnippet(
        trigger: String = ":signature",
        imagePath: String = "",
        isSecret: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Email signature",
            label: "Work signature",
            triggerKeyword: trigger,
            replacementText: "Regards,\nBharath",
            isCaseSensitive: true,
            requireWordBoundary: false,
            isPlainText: false,
            enabled: true,
            imagePath: imagePath,
            createdAt: originalDate,
            updatedAt: originalDate.addingTimeInterval(60),
            usageCount: 41,
            tags: ["work", "email"],
            includeApps: ["com.apple.mail"],
            excludeApps: ["com.example.private"],
            aiTransform: "proofread",
            isSecret: isSecret
        )
    }

    func testNormalDuplicatePreservesEveryAuthoredFieldAndResetsIdentityMetadata() throws {
        let source = fullyPopulatedSnippet()
        let duplicateID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var planner = SnippetDuplicationPlanner(existing: [source])

        let copy = try planner.duplicate(
            source,
            id: duplicateID,
            timestamp: duplicateDate,
            duplicateImage: { _ in XCTFail("A text duplicate must not touch image storage"); return "" }
        )

        XCTAssertEqual(copy.id, duplicateID)
        XCTAssertEqual(copy.triggerKeyword, ":signature-copy")
        XCTAssertEqual(copy.title, source.title)
        XCTAssertEqual(copy.label, source.label)
        XCTAssertEqual(copy.replacementText, source.replacementText)
        XCTAssertEqual(copy.isCaseSensitive, source.isCaseSensitive)
        XCTAssertEqual(copy.requireWordBoundary, source.requireWordBoundary)
        XCTAssertEqual(copy.isPlainText, source.isPlainText)
        XCTAssertEqual(copy.enabled, source.enabled)
        XCTAssertEqual(copy.imagePath, source.imagePath)
        XCTAssertEqual(copy.tags, source.tags)
        XCTAssertEqual(copy.includeApps, source.includeApps)
        XCTAssertEqual(copy.excludeApps, source.excludeApps)
        XCTAssertEqual(copy.aiTransform, source.aiTransform)
        XCTAssertEqual(copy.isSecret, source.isSecret)
        XCTAssertEqual(copy.createdAt, duplicateDate)
        XCTAssertEqual(copy.updatedAt, duplicateDate)
        XCTAssertEqual(copy.usageCount, 0)
    }

    func testImageDuplicateUsesAnIndependentAttachmentAndPreservesAllOtherFields() throws {
        let source = fullyPopulatedSnippet(imagePath: "original.png")
        var planner = SnippetDuplicationPlanner(existing: [source])
        var requestedPath: String?

        let copy = try planner.duplicate(
            source,
            timestamp: duplicateDate,
            duplicateImage: { path in
                requestedPath = path
                return "independent-copy.png"
            }
        )

        XCTAssertEqual(requestedPath, "original.png")
        XCTAssertEqual(copy.imagePath, "independent-copy.png")
        XCTAssertTrue(copy.isImageSnippet)
        XCTAssertEqual(copy.title, source.title)
        XCTAssertEqual(copy.label, source.label)
        XCTAssertEqual(copy.tags, source.tags)
        XCTAssertEqual(copy.includeApps, source.includeApps)
        XCTAssertEqual(copy.excludeApps, source.excludeApps)
        XCTAssertEqual(copy.isPlainText, source.isPlainText)
        XCTAssertEqual(copy.aiTransform, source.aiTransform)
    }

    func testSecretDuplicateIsASafeDisabledDraftRatherThanAnUnbackedSecret() throws {
        let source = fullyPopulatedSnippet(trigger: ":password", isSecret: true)
        var planner = SnippetDuplicationPlanner(existing: [source])

        let copy = try planner.duplicate(
            source,
            timestamp: duplicateDate,
            duplicateImage: { _ in XCTFail("A secret duplicate must not touch image storage"); return "" }
        )

        XCTAssertFalse(copy.isSecret, "A new UUID has no keychain value and must not claim to be a secret")
        XCTAssertFalse(copy.enabled, "An empty draft must not be allowed to expand before the user fills it")
        XCTAssertEqual(copy.replacementText, "")
        XCTAssertEqual(copy.imagePath, "")
        XCTAssertEqual(copy.aiTransform, "")
        XCTAssertEqual(copy.triggerKeyword, ":password-copy")
        XCTAssertEqual(copy.title, source.title)
        XCTAssertEqual(copy.label, source.label)
        XCTAssertEqual(copy.tags, source.tags)
        XCTAssertEqual(copy.includeApps, source.includeApps)
        XCTAssertEqual(copy.excludeApps, source.excludeApps)
        XCTAssertEqual(copy.isCaseSensitive, source.isCaseSensitive)
        XCTAssertEqual(copy.requireWordBoundary, source.requireWordBoundary)
        XCTAssertEqual(copy.isPlainText, source.isPlainText)
    }

    func testBatchDuplicatesReserveTriggersCaseInsensitivelyIncludingEarlierCopies() throws {
        let source = fullyPopulatedSnippet(trigger: ":sig")
        let occupied = [
            source,
            fullyPopulatedSnippet(trigger: ":sig-copy"),
            fullyPopulatedSnippet(trigger: ":SIG-COPY2")
        ]
        var planner = SnippetDuplicationPlanner(existing: occupied)

        let first = try planner.duplicate(source, duplicateImage: { _ in "" })
        let second = try planner.duplicate(source, duplicateImage: { _ in "" })

        XCTAssertEqual(first.triggerKeyword, ":sig-copy3")
        XCTAssertEqual(second.triggerKeyword, ":sig-copy4")
        XCTAssertNotEqual(first.triggerKeyword.lowercased(), second.triggerKeyword.lowercased())
    }

    func testCollisionSuffixNeverPushesATriggerPastTheMatcherLimit() throws {
        let limit = AbbreviationMatcher.matchableTriggerLimit
        let base = String(repeating: "x", count: limit)
        let firstCandidate = String(base.prefix(limit - "-copy".count)) + "-copy"
        let secondCandidate = String(base.prefix(limit - "-copy2".count)) + "-copy2"
        let source = fullyPopulatedSnippet(trigger: base)
        var planner = SnippetDuplicationPlanner(existing: [
            source,
            fullyPopulatedSnippet(trigger: firstCandidate.uppercased()),
            fullyPopulatedSnippet(trigger: secondCandidate)
        ])

        let copy = try planner.duplicate(source, duplicateImage: { _ in "" })

        XCTAssertEqual(copy.triggerKeyword.count, limit)
        XCTAssertTrue(copy.triggerKeyword.hasSuffix("-copy3"))
        XCTAssertFalse([base, firstCandidate, secondCandidate].map { $0.lowercased() }
            .contains(copy.triggerKeyword.lowercased()))
    }

    func testBulkTargetValidationRejectsDuplicateSnippetIDsAndDoesNotConflateGroupIDs() throws {
        let duplicateID = UUID()
        let first = SnippetModel(
            id: duplicateID,
            title: "First",
            triggerKeyword: ":first",
            replacementText: "one"
        )
        let second = SnippetModel(
            id: duplicateID,
            title: "Second",
            triggerKeyword: ":second",
            replacementText: "two"
        )
        let sharedGroupID = UUID()
        let ambiguous = [
            SnippetGroup(id: sharedGroupID, name: "A", snippets: [first]),
            SnippetGroup(id: sharedGroupID, name: "B", snippets: [second])
        ]
        XCTAssertNil(SnippetDuplicationPlanner.validatedTargets(for: [second], in: ambiguous))

        let uniqueSecond = SnippetModel(
            title: "Unique",
            triggerKeyword: ":unique",
            replacementText: "three"
        )
        let duplicateGroupIDs = [
            SnippetGroup(id: sharedGroupID, name: "A", snippets: [first]),
            SnippetGroup(id: sharedGroupID, name: "B", snippets: [uniqueSecond])
        ]
        let targets = try XCTUnwrap(
            SnippetDuplicationPlanner.validatedTargets(for: [uniqueSecond], in: duplicateGroupIDs)
        )
        XCTAssertEqual(targets.count, 1)
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(target.groupIndex, 1)
        XCTAssertEqual(target.snippet, uniqueSecond)
    }

    func testIconOnlyAddGroupButtonHasAnAccessibleButtonIdentityAtRuntime() throws {
        _ = NSApplication.shared
        let controller = SnippetManagerViewController()
        let expectedLabel = LocalizationManager.shared.s("manager.group.add")
        let buttons = descendants(of: controller.view).compactMap { $0 as? NSButton }
        let renderedButtons = buttons.map {
            ($0.title, $0.toolTip ?? "nil", $0.action?.description ?? "nil")
        }.description
        let addGroupButton = try XCTUnwrap(
            buttons.first {
                $0.toolTip == expectedLabel
                    && $0.title.isEmpty
            },
            "Rendered buttons: \(renderedButtons)"
        )

        XCTAssertEqual(addGroupButton.accessibilityRole(), .button)
        XCTAssertEqual(addGroupButton.accessibilityLabel(), expectedLabel)
        XCTAssertEqual(addGroupButton.imagePosition, .imageOnly)
    }

    func testSecretCleanupDebtHasALocalizedProductionRetrySurface() throws {
        let keys = [
            "prefs.advanced.secretCleanup.retry",
            "prefs.advanced.secretCleanup.running",
            "prefs.advanced.secretCleanup.none",
            "prefs.advanced.secretCleanup.result",
            "prefs.advanced.secretCleanup.failed",
        ]
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in keys {
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferences = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/DevTypeAppCore/PreferencesWindowController.swift"
            ),
            encoding: .utf8
        )
        let appDelegate = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/DevTypeAppCore/AppDelegate.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(preferences.contains("action: #selector(retrySecretCleanup)"))
        XCTAssertTrue(preferences.contains("store.requestOrphanSecretCleanupRetry"))
        XCTAssertTrue(
            appDelegate.contains("SnippetStore.shared.requestOrphanSecretCleanupRetry { _ in"),
            "Launch must retry orphan cleanup and observe completion so maintenance UI can refresh."
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

final class SnippetManagerMutationCommitterTests: XCTestCase {
    private func snippet(
        id: String,
        trigger: String,
        imagePath: String = "",
        isSecret: Bool = false
    ) -> SnippetModel {
        SnippetModel(
            id: UUID(uuidString: id)!,
            title: trigger,
            triggerKeyword: trigger,
            replacementText: isSecret ? "" : "body",
            imagePath: imagePath,
            isSecret: isSecret
        )
    }

    private func groups(_ snippets: [SnippetModel]) -> [SnippetGroup] {
        [SnippetGroup(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "General",
            snippets: snippets
        )]
    }

    func testRefusedSaveDiscardsEveryStagedDuplicate() {
        var deleted: [String] = []

        let outcome = SnippetManagerMutationCommitter.finish(
            .refused(.blockedByRemoteChange),
            stagedImagePaths: ["staged.png"],
            deleteImage: { path in
                deleted.append(path)
                return true
            }
        )

        XCTAssertEqual(deleted, ["staged.png"])
        XCTAssertEqual(
            outcome,
            .refused(.blockedByRemoteChange, cleanupFailures: 0)
        )
    }

    func testSuccessfulPlainMutationRemainsUndoableAndDoesNotTouchResources() {
        let original = snippet(
            id: "11111111-1111-1111-1111-111111111111",
            trigger: ":one"
        )
        var edited = original
        edited.enabled = false
        var deleted: [String] = []

        let outcome = SnippetManagerMutationCommitter.finish(
            .saved(before: groups([original]), after: groups([edited])),
            deleteImage: { path in
                deleted.append(path)
                return true
            }
        )

        XCTAssertEqual(deleted, [])
        XCTAssertEqual(
            outcome,
            .committed(allowsModelOnlyUndo: true, cleanupFailures: 0)
        )
    }

    func testRemovingSecretOrImageIsNotOfferedAsModelOnlyUndo() {
        let secret = snippet(
            id: "11111111-1111-1111-1111-111111111111",
            trigger: ":secret",
            isSecret: true
        )
        let image = snippet(
            id: "22222222-2222-2222-2222-222222222222",
            trigger: ":image",
            imagePath: "attachment.png"
        )
        var deleted: [String] = []

        let outcome = SnippetManagerMutationCommitter.finish(
            .saved(before: groups([secret, image]), after: groups([])),
            deleteImage: { path in
                deleted.append(path)
                return true
            }
        )

        XCTAssertEqual(deleted, ["attachment.png"])
        XCTAssertEqual(
            outcome,
            .committed(allowsModelOnlyUndo: false, cleanupFailures: 0)
        )
    }

    func testSuccessfulImageDuplicateIsNotUndoableIntoABrokenRedo() {
        let original = snippet(
            id: "11111111-1111-1111-1111-111111111111",
            trigger: ":image",
            imagePath: "original.png"
        )
        let duplicate = snippet(
            id: "22222222-2222-2222-2222-222222222222",
            trigger: ":image-copy",
            imagePath: "staged.png"
        )

        let outcome = SnippetManagerMutationCommitter.finish(
            .saved(before: groups([original]), after: groups([original, duplicate])),
            stagedImagePaths: ["staged.png"],
            deleteImage: { _ in
                XCTFail("A committed attachment is live and must not be deleted")
                return true
            }
        )

        XCTAssertEqual(
            outcome,
            .committed(allowsModelOnlyUndo: false, cleanupFailures: 0)
        )
    }

    func testCleanupFailureIsExplicitForBothCommittedAndRefusedMutations() {
        let original = snippet(
            id: "11111111-1111-1111-1111-111111111111",
            trigger: ":image",
            imagePath: "old.png"
        )

        let committed = SnippetManagerMutationCommitter.finish(
            .saved(before: groups([original]), after: groups([])),
            deleteImage: { _ in false }
        )
        let refused = SnippetManagerMutationCommitter.finish(
            .unchanged(current: groups([original])),
            stagedImagePaths: ["staged.png"],
            deleteImage: { _ in false }
        )

        XCTAssertEqual(
            committed,
            .committed(allowsModelOnlyUndo: false, cleanupFailures: 1)
        )
        XCTAssertEqual(refused, .unchanged(cleanupFailures: 1))
    }
}

final class SnippetReorderEligibilityTests: XCTestCase {
    func testOnlyAllChipAllowsManualReordering() {
        XCTAssertTrue(SnippetReorderEligibility.isAllowed(
            sortMode: .manual,
            hasConcreteGroup: true,
            filterText: "",
            filterChip: .all
        ))

        for chip in SnippetFilterChip.allCases where chip != .all {
            XCTAssertFalse(
                SnippetReorderEligibility.isAllowed(
                    sortMode: .manual,
                    hasConcreteGroup: true,
                    filterText: "",
                    filterChip: chip
                ),
                "\(chip) is a projection, not the full stored order"
            )
        }
    }

    func testSortGroupAndTextFilterMustAlsoExposeTheStoredProjection() {
        for sortMode in SnippetSortMode.allCases where sortMode != .manual {
            XCTAssertFalse(SnippetReorderEligibility.isAllowed(
                sortMode: sortMode,
                hasConcreteGroup: true,
                filterText: "",
                filterChip: .all
            ))
        }
        XCTAssertFalse(SnippetReorderEligibility.isAllowed(
            sortMode: .manual,
            hasConcreteGroup: false,
            filterText: "",
            filterChip: .all
        ))
        XCTAssertFalse(SnippetReorderEligibility.isAllowed(
            sortMode: .manual,
            hasConcreteGroup: true,
            filterText: "signature",
            filterChip: .all
        ))
        XCTAssertTrue(SnippetReorderEligibility.isAllowed(
            sortMode: .manual,
            hasConcreteGroup: true,
            filterText: "   \n",
            filterChip: .all
        ))
    }
}
