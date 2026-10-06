import XCTest
@testable import ExpanderEngine

/// Contract §3 for DevType: Lappi may annotate the routed row and nothing else. It never
/// inserts a row, never changes the text a row inserts, and never runs anything.
final class LappiAdmissionTests: XCTestCase {

    private let routed = PaletteToolRouter.Routed(query: "date three weeks out", text: "Oct 27, 2026")

    private func answered(_ route: String, noul: Bool = false, degraded: Bool = false) -> LappiReading {
        .modelAnswered(backend: "qd-metal", slots: [
            "route": LappiSlotAnswer(value: noul ? nil : .label(route), conformalSet: nil, score: 0.9, noul: noul, degraded: degraded),
        ])
    }

    private var everyReading: [LappiReading] {
        [
            answered("resolveDate"), answered("none"), answered("findSnippet"),
            .modelAbstained(backend: "qd-metal", slots: [:]),
            .requestRefused(kind: "task_not_trained"),
            .backendFailed(kind: "overloaded"),
        ] + LappiUnavailableReason.allCases.map { .unavailable($0) }
            + LappiNotAskedReason.allCases.map { .notAsked($0) }
    }

    func testNoRoutedRowStaysNoRowWhateverLappiSays() {
        for reading in everyReading {
            XCTAssertNil(LappiRouteAdmission.admit(nil, reading: reading, routedTool: nil), reading.name)
            XCTAssertNil(LappiRouteAdmission.admit(nil, reading: reading, routedTool: "resolveDate"), reading.name)
        }
    }

    func testTheRowsTextAndQueryNeverChange() throws {
        for reading in everyReading {
            let admitted = try XCTUnwrap(LappiRouteAdmission.admit(routed, reading: reading, routedTool: "resolveDate"))
            XCTAssertEqual(admitted.text, routed.text, reading.name)
            XCTAssertEqual(admitted.query, routed.query, reading.name)
        }
    }

    func testOnlyAModelAnswerAnnotates() {
        XCTAssertEqual(LappiRouteAdmission.admit(routed, reading: answered("resolveDate"), routedTool: "resolveDate")?.lappiNote, .agrees)
        XCTAssertEqual(LappiRouteAdmission.admit(routed, reading: answered("runMacro"), routedTool: "resolveDate")?.lappiNote, .differs)
        XCTAssertEqual(LappiRouteAdmission.admit(routed, reading: answered("none"), routedTool: nil)?.lappiNote, .agrees)
        for reading in everyReading where reading.name != "model_answered" {
            XCTAssertNil(LappiRouteAdmission.admit(routed, reading: reading, routedTool: "resolveDate")?.lappiNote, reading.name)
        }
    }

    func testAnAnswerOutsideTheOptionsOrAbstainedDoesNotAnnotate() {
        XCTAssertNil(LappiRouteAdmission.admit(routed, reading: answered("deleteEverything"), routedTool: "resolveDate")?.lappiNote)
        XCTAssertNil(LappiRouteAdmission.admit(routed, reading: answered("resolveDate", degraded: true), routedTool: "resolveDate")?.lappiNote)
        let otherSlot = LappiReading.modelAnswered(backend: "qd-metal", slots: [
            "verdict": LappiSlotAnswer(value: .label("resolveDate"), conformalSet: nil, score: 0.9, noul: false, degraded: false),
        ])
        XCTAssertNil(LappiRouteAdmission.admit(routed, reading: otherSlot, routedTool: "resolveDate")?.lappiNote)
    }

    func testTheAnnotationOnlyChangesTheRowsSubtitle() {
        let loc = LocalizationManager.shared
        let plain = CommandPaletteCatalog.routedHit(routed, loc: loc)
        let noted = CommandPaletteCatalog.routedHit(
            PaletteToolRouter.Routed(query: routed.query, text: routed.text, lappiNote: .differs),
            loc: loc
        )
        XCTAssertEqual(plain.command.subtitleKey, "palette.routed.detail")
        XCTAssertEqual(noted.command.subtitleKey, "palette.routed.detail.lappiDiffers")
        XCTAssertEqual(noted.command.id, plain.command.id)
        XCTAssertEqual(noted.command.action, plain.command.action)
        XCTAssertEqual(noted.insertText, plain.insertText)
        XCTAssertEqual(noted.score, plain.score)
        for key in ["palette.routed.detail.lappiAgrees", "palette.routed.detail.lappiDiffers"] {
            XCTAssertNotNil(LocalizationManager.stringTable(for: .en)[key], key)
        }
    }

    func testTheToolRecorderKeepsTheFirstToolCalled() {
        let recorder = PaletteToolCallRecorder()
        XCTAssertNil(recorder.firstTool)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in recorder.note("findSnippet") }
        recorder.note("runMacro")
        XCTAssertEqual(recorder.firstTool, "findSnippet")
    }
}
