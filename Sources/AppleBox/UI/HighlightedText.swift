import SwiftUI

/// One line of text with its fuzzy-match runs marked, so rows and the preview show matches the same way.
///
/// Built as a single `AttributedString` rather than concatenated `Text` values: concatenation would
/// split the line into many layout runs, and truncation would then cut between them.
struct HighlightedText: View {
    private let attributed: AttributedString

    init(_ text: String, runs: [MatchRun], tint: Color, font: Font) {
        attributed = Self.attributedString(text, runs: runs, tint: tint, font: font)
    }

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Runs come from the matcher and may be stale for the text they are applied to, so each is checked
    /// against the string and skipped when it no longer fits. A stale highlight is cosmetic; a crash is not.
    private static func attributedString(_ text: String, runs: [MatchRun], tint: Color, font: Font) -> AttributedString {
        var result = AttributedString(text)
        result.font = font
        // `AttributedString` backgrounds are square; the token radius applies where a layer can draw it.
        let underlay = tint.opacity(DesignTokens.Palette.matchUnderlayOpacity)
        for run in runs where run.range.upperBound <= text.endIndex {
            guard let lower = AttributedString.Index(run.range.lowerBound, within: result),
                  let upper = AttributedString.Index(run.range.upperBound, within: result),
                  lower < upper else { continue }
            result[lower ..< upper].foregroundColor = tint
            result[lower ..< upper].backgroundColor = underlay
            result[lower ..< upper].font = font.weight(DesignTokens.Typography.matchWeight)
        }
        return result
    }
}
