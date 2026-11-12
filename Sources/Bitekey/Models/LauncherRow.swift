import Foundation

/// One contiguous highlighted span of a row's text. Views render these instead of
/// re-deriving ranges from raw indices, so every row type highlights the same way.
nonisolated struct MatchRun: Equatable, Sendable {
    let range: Range<String.Index>
}

/// Groups fuzzy-match character offsets into contiguous runs.
///
/// `FuzzyMatcher` reports `Character` offsets, not UTF-16 offsets, so a run must
/// cover whole grapheme clusters; walking characters keeps emoji and combining
/// marks from being split mid-cluster. Unsorted, duplicate and out-of-range offsets
/// are tolerated because callers pass matcher output that may be stale for the text.
nonisolated func matchRuns(in text: String, indices: [Int]) -> [MatchRun] {
    let wanted = Set(indices.filter { $0 >= 0 })
    // Offsets past the last wanted one can neither start nor extend a run, so the walk stops there
    // instead of crossing the rest of a clip that can be 256 KiB, on the main actor, per keystroke.
    guard let last = wanted.max() else { return [] }

    var runs: [MatchRun] = []
    var runStart: String.Index?
    var offset = 0
    var index = text.startIndex

    while index < text.endIndex, offset <= last {
        let next = text.index(after: index)
        if wanted.contains(offset) {
            if runStart == nil {
                runStart = index
            }
        } else if let start = runStart {
            runs.append(MatchRun(range: start ..< index))
            runStart = nil
        }
        index = next
        offset += 1
    }
    // The walk ends at the text's end or just past the last wanted offset; either way `index` closes the run.
    if let start = runStart {
        runs.append(MatchRun(range: start ..< index))
    }
    return runs
}

/// Value snapshot of an application result row, built off the main actor so the
/// SwiftUI list never touches the indexer or matcher while rendering.
nonisolated struct AppRowData: Identifiable, Equatable {
    /// Bundle path is unique per installed app, which keeps list identity stable across searches.
    let id: String
    let name: String
    /// Disambiguates same-named apps; nil when the app lives in a standard location.
    let location: String?
    let runs: [MatchRun]
    let isRecent: Bool
}

/// Value snapshot of a clipboard result row, built off the main actor for the same
/// reason as `AppRowData`.
nonisolated struct ClipRowData: Identifiable, Equatable {
    /// Matches the clipboard item id so selection survives live history reordering.
    let id: UUID
    let preview: String
    let kind: ClipKind
    let timestamp: Date
    let runs: [MatchRun]
}
