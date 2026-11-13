import SwiftUI

/// One clipboard result: a kind badge or image thumbnail, the highlighted first line of the clip, and
/// how long ago it was copied on a second line, laid out like an app row so both lists share one rhythm.
///
/// Equatable on its inputs only, for the same reason as `AppRow`. The thumbnail is passed in rather than
/// looked up here because the row value carries no clip content; `ThumbnailClipRow` does the lookup.
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
                    // Fill overflows the slot for any non-square image; framing before the clip crops it to the
                    // slot, because the outer frame only sizes the layout and a wide image would spill past
                    // the selection highlight.
                    .frame(width: DesignTokens.Metrics.thumbnailSize, height: DesignTokens.Metrics.thumbnailSize)
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
                    .foregroundStyle(badgeStyle)
            }
        }
        .frame(width: DesignTokens.Metrics.thumbnailSize, height: DesignTokens.Metrics.thumbnailSize)
        .accessibilityHidden(true)
    }

    /// Kind colors read on the plain list, but on the plum selection capsule most fall near 1:1 in light
    /// mode, below the 3:1 a symbol needs. A selected row uses the label color, as its text does; the
    /// symbol's shape still names the kind there.
    private var badgeStyle: Color {
        isSelected ? Color.primary : DesignTokens.Palette.badge(for: data.kind)
    }

    static func == (lhs: ClipRow, rhs: ClipRow) -> Bool {
        lhs.data == rhs.data && lhs.isSelected == rhs.isSelected && lhs.thumbnail === rhs.thumbnail && lhs.reference == rhs.reference
    }
}

/// A clip row that looks up its own thumbnail and redraws only when that thumbnail finishes decoding.
///
/// Decode notifications used to bump a counter on the whole list, so each finished image redrew every
/// row. Each row now filters the notification by its clip id; text clips never decode, so they never match.
struct ThumbnailClipRow: View, Equatable {
    let data: ClipRowData
    let isSelected: Bool
    let clips: ClipboardModel
    var reference: Date?

    @Environment(\.clipImages) private var images
    /// Bumped when this row's image finishes decoding, so the body asks the cache again.
    @State private var loads = 0

    var body: some View {
        ClipRow(data: data, isSelected: isSelected, thumbnail: thumbnail, reference: reference).equatable()
            .onReceive(NotificationCenter.default.publisher(for: ClipboardImageCache.didLoad).filter(isOwnLoad)) { _ in
                loads &+= 1
            }
    }

    /// Only image clips need content from the history; looking up text clips would be wasted work per row.
    /// Reads `loads` so a finished decode makes the body ask the cache again.
    private var thumbnail: NSImage? {
        _ = loads
        guard data.kind == .image, let item = clips.item(id: data.id) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? DesignTokens.Metrics.fallbackBackingScale
        return images.thumbnail(for: item, pixelSize: DesignTokens.Metrics.thumbnailSize * scale)
    }

    /// Text clips never decode, so the kind check spares them the user-info lookup on every decode.
    private func isOwnLoad(_ note: Notification) -> Bool {
        data.kind == .image && note.userInfo?[ClipboardImageCache.clipIDKey] as? UUID == data.id
    }

    /// Lets the list skip this row's body, and its history lookup, when a list pass leaves its inputs as
    /// they were. The model is compared by identity: it is the one history the row reads from.
    static func == (lhs: ThumbnailClipRow, rhs: ThumbnailClipRow) -> Bool {
        lhs.data == rhs.data && lhs.isSelected == rhs.isSelected && lhs.clips === rhs.clips && lhs.reference == rhs.reference
    }
}
