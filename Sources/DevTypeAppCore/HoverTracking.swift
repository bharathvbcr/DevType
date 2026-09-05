import AppKit

extension NSView {
    /// Replaces every tracking area on this view with a single one covering `bounds`.
    ///
    /// Five hover-styled controls carried a byte-identical `updateTrackingAreas` override
    /// doing exactly this, in three files. Wholesale removal — rather than tracking one
    /// area and removing just it — is the existing behaviour and is what makes the override
    /// idempotent across the repeated `updateTrackingAreas` calls AppKit makes during
    /// layout.
    ///
    /// Not for a view inside a recycled table cell: those want one retained area with
    /// `.inVisibleRect` so scrolling does not invalidate the rect. `SnippetManagerViewController`
    /// does that and is deliberately not a caller.
    func replaceTrackingAreaOverBounds(
        options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
    ) {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        ))
    }
}
