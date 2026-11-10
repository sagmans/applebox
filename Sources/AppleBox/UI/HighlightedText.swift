import SwiftUI

/// One line of text with its fuzzy-match runs marked, so rows show matches the same way everywhere.
///
/// Built as a single `AttributedString` rather than concatenated `Text` values: concatenation would
/// split the line into many layout runs, and truncation would then cut between them.
struct HighlightedText: View {
    /// A match that starts beyond this many characters would be cut off by tail truncation, which paints
    /// the ellipsis instead of the match; past it the line is windowed around the match.
    private static let matchWindowLead = 32
    /// Characters kept before the first match when windowing, so the match keeps some context.
    private static let matchWindowContext = 12
    /// Marks that the start of the line was dropped.
    private static let leadingEllipsis = "…"

    private let attributed: AttributedString

    /// `isSelected` decides the match color: on the selection capsule the accent-colored text would sit
    /// on an accent fill and vanish, so the label color is used and weight alone carries the match.
    init(_ text: String, runs: [MatchRun], isSelected: Bool, font: Font) {
        let matchColor = isSelected ? Color.primary : DesignTokens.Palette.matchText
        attributed = Self.attributedString(text, runs: runs, matchColor: matchColor, font: font)
    }

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Runs come from the matcher and may be stale for the text they are applied to, so each is checked
    /// against the string and skipped when it no longer fits. A stale highlight is cosmetic; a crash is not.
    private static func attributedString(_ text: String, runs: [MatchRun], matchColor: Color, font: Font) -> AttributedString {
        var result = AttributedString(text)
        result.font = font
        var firstMatch: String.Index?
        for run in runs where run.range.upperBound <= text.endIndex {
            guard let lower = AttributedString.Index(run.range.lowerBound, within: result),
                  let upper = AttributedString.Index(run.range.upperBound, within: result),
                  lower < upper else { continue }
            result[lower ..< upper].foregroundColor = matchColor
            result[lower ..< upper].font = font.weight(DesignTokens.Typography.matchWeight)
            firstMatch = firstMatch.map { min($0, run.range.lowerBound) } ?? run.range.lowerBound
        }
        guard let firstMatch, text.distance(from: text.startIndex, to: firstMatch) > matchWindowLead else {
            return result
        }
        return windowed(result, text: text, firstMatch: firstMatch, font: font)
    }

    /// Drops the start of the line so the first match stays visible. Slicing the already-styled string keeps
    /// every run's attributes aligned without re-mapping indices.
    private static func windowed(_ styled: AttributedString, text: String, firstMatch: String.Index, font: Font) -> AttributedString {
        let start = text.index(firstMatch, offsetBy: -matchWindowContext, limitedBy: text.startIndex) ?? text.startIndex
        guard let lower = AttributedString.Index(start, within: styled) else { return styled }
        var prefix = AttributedString(leadingEllipsis)
        prefix.font = font
        return prefix + AttributedString(styled[lower...])
    }
}
