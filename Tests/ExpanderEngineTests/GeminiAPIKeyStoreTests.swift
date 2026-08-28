import XCTest
@testable import ExpanderEngine

final class GeminiAPIKeyStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? GeminiAPIKeyStore.delete()
    }

    override func tearDown() {
        try? GeminiAPIKeyStore.delete()
        super.tearDown()
    }

    func testSaveLoadDeleteLifecycle() throws {
        // Initially no key
        XCTAssertFalse(GeminiAPIKeyStore.hasKey)
        XCTAssertNil(GeminiAPIKeyStore.load())

        // Save key
        let testKey = "AIzaSyTestKey123456789"
        try GeminiAPIKeyStore.save(testKey)

        XCTAssertTrue(GeminiAPIKeyStore.hasKey)
        XCTAssertEqual(GeminiAPIKeyStore.load(), testKey)

        // Overwrite key
        let updatedKey = "AIzaSyUpdatedKey987654321"
        try GeminiAPIKeyStore.save(updatedKey)
        XCTAssertEqual(GeminiAPIKeyStore.load(), updatedKey)

        // Delete key
        try GeminiAPIKeyStore.delete()
        XCTAssertFalse(GeminiAPIKeyStore.hasKey)
        XCTAssertNil(GeminiAPIKeyStore.load())
    }
}
