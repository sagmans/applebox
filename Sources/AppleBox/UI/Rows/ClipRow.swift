import SwiftUI

/// One clipboard result: a kind badge or image thumbnail and the highlighted first line of the clip.
///
/// Equatable on its inputs only, for the same reason as `AppRow`. The thumbnail is passed in rather than
/// looked up here because the row value carries no clip content, and decoding belongs to the list.
struct ClipRow: View, Equatable {
    let data: ClipRowData
    let isSelected: Bool
    /// Decoded image for image clips; nil for text, or when decoding failed, which falls back to the badge.
    var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: DesignTokens.Metrics.inlineSpacing) {
            leading
            HighlightedText(data.preview, runs: data.runs, isSelected: isSelected, font: DesignTokens.Typography.rowTitle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Metrics.rowHorizontalPadding)
        .frame(height: DesignTokens.Layout.rowHeight)
    }

    /// The thumbnail identifies an image clip better than its placeholder text; every other clip, and an
    /// image that failed to decode, shows the kind badge so the row never has an empty slot.
    private var leading: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.imageCornerRadius))
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
        lhs.data == rhs.data && lhs.isSelected == rhs.isSelected && lhs.thumbnail === rhs.thumbnail
    }
}
