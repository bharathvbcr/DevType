import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

final class EditorKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Wired by the controller so ⌘Return saves even while the multi-line
    /// replacement editor holds focus.
    var saveHandler: (() -> Void)?

    /// Return/Enter routing, resolved at the panel so view order doesn't matter:
    /// a focused multi-line text view gets the newline *before* the Save button's
    /// "\r" key equivalent can swallow it, ⌘Return saves from anywhere, and
    /// single-line fields (field editors) keep their Return → Save path.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
            let significant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if significant == .command, let saveHandler {
                saveHandler()
                return true
            }
            if significant.isEmpty,
               let textView = firstResponder as? NSTextView,
               !textView.isFieldEditor,
               textView.isEditable,
               !textView.hasMarkedText() {
                textView.insertNewline(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
