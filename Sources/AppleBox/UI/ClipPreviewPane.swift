import SwiftUI

/// The clip detail shown beside the list: a header with kind, time and size, then the full text or image.
///
/// Reads the clip from the model by id, so the pane follows the selection and shows nothing when no row
/// is highlighted.
struct ClipPreviewPane: View {
    @Bindable var model: LauncherModel

    @Environment(\.clipImages) private var images
    /// Memo of character counts so a keystroke does not recount a clip of hundreds of KiB.
    @State private var counts = CharacterCountMemo()

    private var selectedRow: ClipRowData? {
        guard let index = model.selection, model.clips.rows.indices.contains(index) else { return nil }
        return model.clips.rows[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.previewSpacing) {
            if let row = selectedRow, let item = model.clips.item(id: row.id) {
                // One cache lookup per evaluation, shared by header and body.
                let image = item.contentType == .image ? images.image(for: item) : nil
                header(row: row, item: item, image: image)
                content(row: row, item: item, image: image)
            }
        }
        .padding(DesignTokens.Metrics.previewPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DesignTokens.Copy.previewLabel)
    }

    /// Kind, copy time and size, in a quiet row so the content stays the focus.
    private func header(row: ClipRowData, item: ClipboardItem, image: NSImage?) -> some View {
        HStack(spacing: DesignTokens.Metrics.tightSpacing) {
            Image(systemName: DesignTokens.Symbol.badge(for: row.kind))
                .foregroundStyle(DesignTokens.Palette.badge(for: row.kind))
            if case let .link(host) = row.kind {
                Text(host)
                    .padding(.horizontal, DesignTokens.Metrics.capsuleHorizontalPadding)
                    .padding(.vertical, DesignTokens.Metrics.capsuleVerticalPadding)
                    .background(DesignTokens.Palette.badge(for: row.kind).opacity(DesignTokens.Palette.linkHostOpacity), in: .capsule)
                    .lineLimit(1)
            }
            Text(item.timestamp, format: DesignTokens.clipDateFormat)
            Spacer(minLength: 0)
            Text(sizeDescription(item: item, image: image))
        }
        .font(DesignTokens.Typography.previewHeader)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func content(row: ClipRowData, item: ClipboardItem, image: NSImage?) -> some View {
        if item.contentType == .image {
            imageBody(image: image)
        } else {
            PreviewTextView(
                itemID: item.id,
                content: item.content,
                matchedIndices: model.clips.matchedIndices(id: item.id),
                // The row's kind already applied the code rule to the clip's start; re-running it over
                // a 256 KiB clip on every model change would cost more than the rule is worth.
                isMonospaced: row.kind == .code,
                tint: DesignTokens.Palette.clipTint
            )
        }
    }

    /// A decode failure shows a visible message, because an empty pane reads as "still loading".
    @ViewBuilder
    private func imageBody(image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.imageCornerRadius))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(DesignTokens.Identifier.previewImage)
                .accessibilityLabel(DesignTokens.Copy.previewLabel)
        } else {
            ContentUnavailableView(DesignTokens.Copy.imageUnavailable, systemImage: DesignTokens.Symbol.missingImage)
                .accessibilityIdentifier(DesignTokens.Identifier.previewImage)
        }
    }

    /// Characters for text and pixels for images, the two sizes a user can reason about.
    private func sizeDescription(item: ClipboardItem, image: NSImage?) -> String {
        if item.contentType == .image {
            guard let rep = image?.representations.first else { return "" }
            return DesignTokens.Copy.pixelSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return DesignTokens.Copy.characterCount(counts.characters(in: item))
    }
}

/// Counts grapheme characters once per clip. Reference type so filling it during `body` is not a state
/// change; bounded so a long session cannot grow it without limit.
private final class CharacterCountMemo {
    private var counts: [UUID: Int] = [:]
    private static let limit = 64

    func characters(in item: ClipboardItem) -> Int {
        if let known = counts[item.id] {
            return known
        }
        if counts.count >= Self.limit {
            counts.removeAll()
        }
        let count = item.content.count
        counts[item.id] = count
        return count
    }
}
