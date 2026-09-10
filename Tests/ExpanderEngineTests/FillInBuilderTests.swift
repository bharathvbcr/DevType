import XCTest
@testable import ExpanderEngine

final class FillInBuilderTests: XCTestCase {
    func testFillTextWithEmptyDefault() {
        let result = FillInBuilder.fillText(name: "first_name", defaultValue: "")
        XCTAssertEqual(result, "%filltext:name=first_name%")
    }

    func testFillTextWithDefaultValueAndSanitization() {
        let result = FillInBuilder.fillText(name: "user:name%", defaultValue: "Alice%Smith")
        XCTAssertEqual(result, "%filltext:name=username:default=AliceSmith%")
    }

    func testFillAreaWithEmptyDefault() {
        let result = FillInBuilder.fillArea(name: "notes", defaultValue: "")
        XCTAssertEqual(result, "%fillarea:name=notes%")
    }

    func testFillAreaWithDefaultValue() {
        let result = FillInBuilder.fillArea(name: "address", defaultValue: "123 Main St")
        XCTAssertEqual(result, "%fillarea:name=address:default=123 Main St%")
    }

    func testFillPopupWithoutDefault() {
        let result = FillInBuilder.fillPopup(name: "role", options: ["Admin", "User", "Guest"], defaultValue: "")
        XCTAssertEqual(result, "%fillpopup:name=role:Admin:User:Guest%")
    }

    func testFillPopupWithDefaultAndSanitization() {
        let result = FillInBuilder.fillPopup(name: "status:code%", options: ["opt:1%", "opt:2%"], defaultValue: "opt1%")
        XCTAssertEqual(result, "%fillpopup:name=statuscode:opt1:opt2:default=opt1%")
    }

    func testFillPopupWithEmptyOptionsFilteredOut() {
        let result = FillInBuilder.fillPopup(name: "choose", options: [":", "%", "Valid"], defaultValue: "")
        XCTAssertEqual(result, "%fillpopup:name=choose:Valid%")
    }

    func testContentIsRepresentable() {
        XCTAssertTrue(FillInBuilder.contentIsRepresentable("Hello 50% discount"))
        XCTAssertTrue(FillInBuilder.contentIsRepresentable("Double %% percent"))
        XCTAssertFalse(FillInBuilder.contentIsRepresentable("Bad %fillpartend% marker"))
        XCTAssertFalse(FillInBuilder.contentIsRepresentable("Bad %fillpart: name=x% marker"))
        XCTAssertFalse(FillInBuilder.contentIsRepresentable("Bad %case:upper% marker"))
        XCTAssertFalse(FillInBuilder.contentIsRepresentable("Bad %caseend% marker"))
    }

    func testFillPartSuccess() throws {
        let yes = try FillInBuilder.fillPart(name: "greeting", includeByDefault: true, content: "Hello World")
        XCTAssertEqual(yes, "%fillpart:name=greeting:default=yes%Hello World%fillpartend%")

        let no = try FillInBuilder.fillPart(name: "legal:footer%", includeByDefault: false, content: "All rights reserved.")
        XCTAssertEqual(no, "%fillpart:name=legalfooter:default=no%All rights reserved.%fillpartend%")
    }

    func testFillPartRejectsUnrepresentableContent() {
        XCTAssertThrowsError(
            try FillInBuilder.fillPart(name: "nested", includeByDefault: true, content: "prefix %case:upper% suffix")
        ) { error in
            XCTAssertEqual(error as? FillInBuilder.BuilderError, .contentNotRepresentable)
        }
    }
}
