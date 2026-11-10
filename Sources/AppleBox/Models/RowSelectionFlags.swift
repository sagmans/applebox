import Observation

/// Whether one list position holds the selection.
///
/// One observable object per position, instead of rows reading `LauncherModel.selection`, because
/// Observation tracks a property as a whole: every row reading the shared index was invalidated on each
/// arrow key, so a held key redrew every materialized row. A row reading only its own flag is invalidated
/// only when it gains or loses the selection.
@Observable
final class RowSelectionFlag {
    fileprivate(set) var isSelected = false
}

/// The flags of the shown list, mirroring `LauncherModel.selection`.
///
/// The model updates them in the same mutation as the selection, so the rows and the selection never
/// disagree for a frame: an opening list draws its capsule at once, and a list that returns after the
/// empty state never shows the capsule where an earlier selection left it.
///
/// Not observable itself: views read the flags, never this registry, so handing out or adding a flag
/// while a body runs invalidates nothing. Flags are keyed by position, like the selection, so a refreshed
/// result set keeps the highlight on the same position as the model does. Positions that left the list
/// keep a flag that is false; the registry grows at most to the longest list shown, which stays small.
final class RowSelectionFlags {
    private var flags: [Int: RowSelectionFlag] = [:]
    private var selected: Int?

    /// The flag for a position, created on first use with the current selection, so a row materialized
    /// after the selection moved still starts in the right state.
    func flag(at index: Int) -> RowSelectionFlag {
        if let flag = flags[index] {
            return flag
        }
        let flag = RowSelectionFlag()
        flag.isSelected = index == selected
        flags[index] = flag
        return flag
    }

    /// Moves the selection by touching only the position that loses it and the one that gains it.
    func select(_ index: Int?) {
        guard index != selected else { return }
        if let selected {
            flags[selected]?.isSelected = false
        }
        selected = index
        if let index {
            flags[index]?.isSelected = true
        }
    }
}
