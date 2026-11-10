import SwiftUI

/// One clipboard result: a kind badge or image thumbnail, the highlighted first line of the clip, and
/// how long ago it was copied on a second line, laid out like an app row so both lists share one rhythm.
///
/// Equatable on its inputs only, for the same reason as `AppRow`. The thumbnail is passed in rather than
/// looked up here because the row value carries no clip content, and decoding belongs to the list.
struct ClipRow: View, Equatable {
    let data: ClipRowData
    let isSelected: Bool
    /// Decoded image for image clips; nil for text, or when decoding failed, which falls back to the badge.
    var thumbnail: NSImage?
    /// Fixed "now" for tests; nil uses the real time.
    var reference: Date?

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: DesignTokens.Metrics.inlineSpacing) {
            leading
            // The time sits under the text, not beside it, so the narrow clip list gives the clip text the
            // whole row width before truncating it.
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.rowTextSpacing) {
                HighlightedText(data.preview, runs: data.runs, isSelected: isSelected, font: DesignTokens.Typography.rowTitle)
                Text(verbatim: DesignTokens.relativeTime(data.timestamp, reference: reference, locale: locale))
                    .font(DesignTokens.Typography.rowSubtitle)
                    .foregroundStyle(RowSubtitle.style(isSelected: isSelected))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Metrics.rowHorizontalPadding)
        .frame(height: DesignTokens.Layout.rowHeight)
    }

    /// The thumbnail identifies an image clip better than its placeholder text, and a swatch a color; every other clip, and an
    /// image that failed to decode, shows the kind badge so the row never has an empty slot.
    private var leading: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.imageCornerRadius))
            } else if case let .color(swatch) = data.kind {
                // The clip's own color says more than a palette icon: the user sees the color they copied.
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.swatchCornerRadius)
                    .fill(swatch)
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Metrics.swatchCornerRadius)
                            .strokeBorder(Color.primary.opacity(DesignTokens.Palette.swatchOutlineOpacity), lineWidth: DesignTokens.Metrics.hairline)
                    }
            } else {
                Image(systemName: DesignTokens.Symbol.badge(for: data.kind))
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(DesignTokens.Palette.badge(for: data.kind))
            }
        }
        .frame(width: DesignTokens.Metrics.thumbnailSize, height: DesignTokens.Metrics.thumbnailSize)
        .accessibilityHidden(true)
    }

    static func == (lhs: ClipRow, rhs: ClipRow) -> Bool {
        lhs.data == rhs.data && lhs.isSelected == rhs.isSelected && lhs.thumbnail === rhs.thumbnail && lhs.reference == rhs.reference
    }
}
