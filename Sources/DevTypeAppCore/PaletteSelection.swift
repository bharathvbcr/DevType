import AppKit

/// Keyboard selection over a palette list whose rows interleave selectable items with
/// non-selectable section headers.
///
/// `InlineSearchController` and `MacroPaletteController` carried byte-identical copies of
/// all three of these (`moveSelection` 125 parse nodes, `firstSelectableIndex` 100,
/// `applySelection` 100). They are free functions over `count` + an `isSelectable` probe
/// rather than a protocol, so neither controller has to widen the access of its `rows`,
/// `selection` or `tableView` to share them.
enum PaletteSelection {
    /// First selectable index at or after `start`, walking by `step` until the list ends.
    /// `nil` when the list is empty or holds nothing selectable in that direction.
    static func firstSelectableIndex(
        from start: Int,
        step: Int,
        count: Int,
        isSelectable: (Int) -> Bool
    ) -> Int? {
        guard count > 0 else { return nil }
        var index = start
        while index >= 0 && index < count {
            if isSelectable(index) { return index }
            index += step
        }
        return nil
    }

    /// Where an arrow key lands, or `nil` to leave the selection where it is — which is
    /// what happens at either end, so holding an arrow key stops rather than wrapping.
    ///
    /// A negative `selection` means nothing is selected yet: the first press then enters
    /// the list from the end the key came from, rather than from wherever `-1 + delta` fell.
    static func next(
        from selection: Int,
        delta: Int,
        count: Int,
        isSelectable: (Int) -> Bool
    ) -> Int? {
        guard count > 0 else { return nil }
        let start = selection < 0 ? (delta > 0 ? 0 : count - 1) : selection + delta
        return firstSelectableIndex(
            from: start,
            step: delta > 0 ? 1 : -1,
            count: count,
            isSelectable: isSelectable
        )
    }

    /// Pushes `index` to the table, or clears the selection when it is out of range.
    ///
    /// Range is checked against the model's `count`, not `table.numberOfRows`: mid-reload
    /// the two disagree, and the model is the one the caller just decided against.
    static func apply(_ index: Int, to table: NSTableView, count: Int, scroll: Bool) {
        guard (0..<count).contains(index) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(index) }
    }
}
