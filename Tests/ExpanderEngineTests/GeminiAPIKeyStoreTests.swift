import XCTest
@testable import ExpanderEngine

final class GeminiAPIKeyStoreTests: XCTestCase {
    private let testServiceName = "com.devtype.gemini-api-key.unit-tests"

    override func setUp() {
        super.setUp()
        try? GeminiAPIKeyStore.delete(serviceName: testServiceName)
    }

    override func tearDown() {
        try? GeminiAPIKeyStore.delete(serviceName: testServiceName)
        super.tearDown()
    }

    func testSaveLoadDeleteLifecycle() throws {
        // Initially no key
        XCTAssertNil(GeminiAPIKeyStore.load(serviceName: testServiceName))

        // Save key
        let testKey = "AIzaSyTestKey123456789"
        try GeminiAPIKeyStore.save(testKey, serviceName: testServiceName)

        XCTAssertEqual(GeminiAPIKeyStore.load(serviceName: testServiceName), testKey)

        // Overwrite key
        let updatedKey = "AIzaSyUpdatedKey987654321"
        try GeminiAPIKeyStore.save(updatedKey, serviceName: testServiceName)
        XCTAssertEqual(GeminiAPIKeyStore.load(serviceName: testServiceName), updatedKey)

        // Delete key
        try GeminiAPIKeyStore.delete(serviceName: testServiceName)
        XCTAssertNil(GeminiAPIKeyStore.load(serviceName: testServiceName))
    }
}
