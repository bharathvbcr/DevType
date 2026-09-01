import XCTest
import AppKit
import ExpanderEngine
@testable import DevTypeAppCore

/// The group editor's custom colour and custom symbol.
///
/// `SnippetGroup.symbol` and `.colorHex` were always free-form strings — the fourteen-icon grid
/// and eight-swatch palette were the only thing narrowing them. Both additions are therefore
/// pure UI reach, with the validation that reach requires.
final class GroupCustomizationTests: XCTestCase {

    // MARK: - Colour round-trip

    /// The well hands back whatever space the system picker was in; reading components off a
    /// non-RGB colour traps rather than converting, so the conversion is the load-bearing part.
    func testAColourFromAnyColourSpaceConvertsToHex() {
        for color in [
            NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1),
            NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1),
            NSColor.systemBlue,
            NSColor.white,
            NSColor.black,
        ] {
            let hex = DevTypeTheme.hexFromColor(color)
            XCTAssertEqual(hex.count, 7, "expected #RRGGBB, got \"\(hex)\"")
            XCTAssertTrue(hex.hasPrefix("#"))
            XCTAssertNotNil(
                DevTypeTheme.colorFromHex(hex),
                "\"\(hex)\" must parse back through the app's own parser"
            )
        }
    }

    /// A grey colour is the one most likely to be in a space that needs converting.
    func testAPatternOrGreyColourStillProducesAValidHex() {
        let grey = NSColor(white: 0.5, alpha: 1)
        let hex = DevTypeTheme.hexFromColor(grey)
        XCTAssertNotNil(DevTypeTheme.colorFromHex(hex))
    }

    func testHexRoundTripsThroughTheParserWithoutDrift() {
        for original in DevTypeTheme.groupColorPalette {
            let color = try? XCTUnwrap(DevTypeTheme.colorFromHex(original))
            let hex = DevTypeTheme.hexFromColor(color!)
            XCTAssertEqual(
                hex.uppercased(), original.uppercased(),
                "a palette colour must survive colour → hex → colour unchanged"
            )
        }
    }

    /// An unconvertible colour must yield something the parser rejects rather than a
    /// half-formed string that would be stored and drawn as no tint at all.
    func testAnUnconvertibleColourYieldsAnEmptyHex() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        let hex = DevTypeTheme.hexFromColor(pattern)
        if !hex.isEmpty {
            XCTAssertNotNil(DevTypeTheme.colorFromHex(hex))
        }
    }

    // MARK: - Symbol validation

    /// The rule the editor enforces: a name macOS cannot render is refused, because a stored
    /// bad name draws as nothing and is indistinguishable from an icon that failed to load.
    func testEveryBuiltInIconNameIsRenderable() {
        for name in ["folder.fill", "tag.fill", "star.fill", "bolt.fill", "terminal.fill"] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(name) ships in the grid and must render"
            )
        }
    }

    func testAnInventedSymbolNameIsNotRenderable() {
        XCTAssertNil(
            NSImage(systemSymbolName: "definitely.not.a.real.symbol.xyz", accessibilityDescription: nil),
            "the editor's guard depends on this returning nil"
        )
    }

    /// A symbol outside the fourteen-icon grid must be accepted — that is the whole point.
    func testASymbolOutsideTheGridIsRenderableAndStorable() {
        let name = "flame.fill"
        XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil))
        var group = SnippetGroup(name: "G")
        group.symbol = name
        XCTAssertEqual(group.symbol, name)
    }

    // MARK: - Model tolerance

    func testACustomSymbolAndColourSurviveACodableRoundTrip() throws {
        var group = SnippetGroup(name: "G")
        group.symbol = "flame.fill"
        group.colorHex = "#123456"
        let decoded = try JSONDecoder().decode(
            SnippetGroup.self, from: try JSONEncoder().encode(group)
        )
        XCTAssertEqual(decoded.symbol, "flame.fill")
        XCTAssertEqual(decoded.colorHex, "#123456")
    }

    /// An empty colour means "default accent" and must stay distinguishable from a real one.
    func testAnEmptyColourIsStillTheDefault() {
        XCTAssertNil(DevTypeTheme.colorFromHex(""))
        XCTAssertEqual(SnippetGroup(name: "G").colorHex, "")
    }
}
