import XCTest
@testable import DevTypeAppCore

final class PermissionDiagnosticsCopyTests: XCTestCase {
    func testFilteredProjectionContainsExactlyTheVisibleMatchingLines() {
        let report = "Header\nAlpha permission denied\nbeta ready\nÁLPHA retry"

        let projection = DiagnosticReportProjection.make(
            report: report,
            query: "  alpha  "
        )

        XCTAssertEqual(projection.text, "Alpha permission denied\nÁLPHA retry")
        XCTAssertEqual(projection.matchingLineCount, 2)
        XCTAssertEqual(projection.totalLineCount, 4)
        XCTAssertTrue(projection.isFiltered)
    }

    func testUnfilteredProjectionPreservesTheReportByteForByte() {
        let report = "Header\nline with trailing spaces   \n\nfinal\n"

        let projection = DiagnosticReportProjection.make(report: report, query: " \n\t ")

        XCTAssertEqual(projection.text, report)
        XCTAssertEqual(projection.matchingLineCount, 5)
        XCTAssertEqual(projection.totalLineCount, 5)
        XCTAssertFalse(projection.isFiltered)
    }

    func testNoMatchProducesAnEmptyNonCopyableProjection() {
        let projection = DiagnosticReportProjection.make(
            report: "Permission ready\nTap active",
            query: "voice"
        )

        XCTAssertEqual(projection.text, "")
        XCTAssertEqual(projection.matchingLineCount, 0)
        XCTAssertEqual(projection.totalLineCount, 2)
        XCTAssertTrue(projection.isFiltered)
        XCTAssertFalse(projection.isCopyable)
    }
}
