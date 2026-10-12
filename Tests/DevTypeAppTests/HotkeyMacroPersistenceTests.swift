import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// An undecodable `devtype.hotkeyMacros` value used to load as `[]`, and the next
/// `HotkeyPreferences.saveMacros` replaced it. The raw bytes must survive in a quarantine key.
final class HotkeyMacroPersistenceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "DevTypeHotkeyMacros-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        PersistedFileLoader.observer = nil
    }

    override func tearDown() {
        PersistedFileLoader.observer = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private let corrupt = Data("[{\"keyCode\": \"not a number\"".utf8)

    private func preservedCopies() -> [Data] {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("devtype.hotkeyMacros.") }
            .compactMap { $0.value as? Data }
    }

    func testCorruptMacrosArePreservedAfterNextSaveAndLogged() {
        let lock = NSLock()
        var lines: [String] = []
        PersistedFileLoader.observer = { lock.lock(); lines.append($0); lock.unlock() }
        defaults.set(corrupt, forKey: HotkeyPreferences.macrosKey)

        XCTAssertTrue(HotkeyManager.loadMacros(defaults: defaults).isEmpty)
        HotkeyPreferences.saveMacros(
            [HotkeyMacroAction(id: 0, keyCode: 1, modifiers: 256, kind: .insertText, argument: "hi")],
            defaults: defaults
        )

        XCTAssertTrue(preservedCopies().contains(corrupt), "corrupt macros were overwritten")
        XCTAssertEqual(HotkeyManager.loadMacros(defaults: defaults).count, 1)
        lock.lock(); defer { lock.unlock() }
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Hotkey macros"), joined)
        XCTAssertTrue(joined.contains("code="), joined)
    }

    func testSaveWithoutPriorLoadStillPreservesCorruptMacros() {
        defaults.set(corrupt, forKey: HotkeyPreferences.macrosKey)
        HotkeyPreferences.saveMacros([], defaults: defaults)
        XCTAssertTrue(preservedCopies().contains(corrupt))
    }

    func testValidAndAbsentMacrosCreateNoQuarantine() {
        XCTAssertTrue(HotkeyManager.loadMacros(defaults: defaults).isEmpty)
        HotkeyPreferences.saveMacros(
            [HotkeyMacroAction(id: 0, keyCode: 1, modifiers: 256, kind: .insertText, argument: "a")],
            defaults: defaults
        )
        XCTAssertEqual(HotkeyManager.loadMacros(defaults: defaults).count, 1)
        XCTAssertTrue(preservedCopies().isEmpty)
    }

    func testWrongTypeValueIsPreserved() {
        defaults.set("a string where data belongs", forKey: HotkeyPreferences.macrosKey)
        _ = HotkeyManager.loadMacros(defaults: defaults)
        // `data(forKey:)` coerces nothing here, so the load sees nil; the string must still be kept.
        HotkeyPreferences.saveMacros([], defaults: defaults)
        let kept = defaults.dictionaryRepresentation()
            .contains { $0.key.hasPrefix("devtype.hotkeyMacros.unreadable") }
        XCTAssertTrue(kept)
    }
}
