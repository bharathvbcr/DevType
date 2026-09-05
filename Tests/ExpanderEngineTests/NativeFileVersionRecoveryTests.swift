import Foundation
import XCTest
@testable import ExpanderEngine

final class NativeFileVersionRecoveryTests: XCTestCase {
    func testCoordinatedAdoptionPreservesBackupBeforeRemovingCapturedNativeVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let original = Data("original".utf8)
        let selected = Data("selected".utf8)
        try original.write(to: file)
        var coordinatorError: NSError?
        var thrown: Error?
        var ran = false
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinatorError) { url in
            do {
                let version = try NSFileVersion.addOfItem(at: url, withContentsOf: url, options: [])
                let identifier = version.persistentIdentifier
                XCTAssertEqual(try Data(contentsOf: version.url), original)
                let outcome = LibraryConflictRecovery.resolve(
                    fileURL: url, recoveryRoot: root.appendingPathComponent("recovery"),
                    localCandidate: selected, versions: [.init(url: version.url, remove: { try version.remove() })],
                    validate: { XCTAssertEqual($0, selected) })
                guard case .adopted(let adopted, let recovery, nil) = outcome else { return XCTFail("Native adoption failed: \(outcome)") }
                XCTAssertEqual(adopted, selected)
                XCTAssertEqual(try Data(contentsOf: url), selected)
                XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("alternative-0.json")), original)
                XCTAssertNil(NSFileVersion.version(itemAt: url, forPersistentIdentifier: identifier))
                ran = true
            } catch { thrown = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
        XCTAssertTrue(ran, "A coordinator that did not run is not a passing native test")
    }
}
