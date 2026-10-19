import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Stable target for undo blocks across a localized controller rebuild. `NSUndoManager` does not
/// retain block targets, so the active controller retains this object and rebinds its weak owner;
/// previously registered actions then reach the replacement controller without retaining the old
/// view hierarchy.
final class SnippetManagerUndoTarget: NSObject {
    weak var owner: SnippetManagerViewController?
}
