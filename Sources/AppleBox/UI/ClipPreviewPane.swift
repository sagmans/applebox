import SwiftUI

/// The clip detail shown beside the list: a header with kind, time and size, then the full text or image.
///
/// Reads the clip from the model by id, so the pane follows the selection and shows nothing when no row
/// is highlighted.
struct ClipPreviewPane: View {
    @Bindable var model: LauncherModel

    @Environment(\.clipImages) private var images
    @Environment(\.appIcons) private var icons
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Memo of character counts so a keystroke does not recount a clip of hundreds of KiB.
    @State private var counts = CharacterCountMemo()
    /// Bumped when a clip image finishes decoding in the background, so a pane showing the pending
    /// state reads the cache again.
    @State private var imageLoads = 0

    private var selectedRow: ClipRowData? {
        guard let index = model.selection, model.clips.rows.indices.contains(index) else { return nil }
        return model.clips.rows[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.previewSpacing) {
            if let row = selectedRow, let item = model.clips.item(id: row.id) {
                // Read so a finished background decode redraws the pane.
                let _ = imageLoads
                // One cache lookup per evaluation, shared by header and body.
                let image = item.contentType == .image ? images.image(for: item) : .unavailable
                // Keyed by clip so a new selection cross-fades; the stack overlaps old and new header
                // during the fade instead of stacking them and pushing the body down.
                ZStack(alignment: .topLeading) {
                    header(row: row, item: item, image: image)
                        .id(row.id)
                        .transition(.opacity)
                }
                content(row: row, item: item, image: image)
            }
        }
        .animation(DesignTokens.motion(DesignTokens.Motion.previewChange, reduceMotion: reduceMotion), value: selectedRow?.id)
        .padding(DesignTokens.Metrics.previewPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: ClipboardImageCache.didLoad)) { _ in
            imageLoads &+= 1
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DesignTokens.Copy.previewPaneLabel)
        .accessibilityHint(DesignTokens.Copy.previewPaneHelp)
    }

    /// Kind, copy time and size, in a quiet row so the content stays the focus.
    private func header(row: ClipRowData, item: ClipboardItem, image: ClipImageLookup) -> some View {
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
            if let source = item.sourceBundleID.flatMap(SourceAppResolver.shared.app(forBundleID:)) {
                sourceLabel(source)
            }
            Spacer(minLength: 0)
            Text(sizeDescription(item: item, image: image))
        }
        .font(DesignTokens.Typography.previewHeader)
        .foregroundStyle(.secondary)
    }

    /// Where the clip was copied from, so similar clips can be told apart by origin. Truncates first when
    /// the header is tight, because the date and size matter more.
    private func sourceLabel(_ source: SourceApp) -> some View {
        HStack(spacing: DesignTokens.Metrics.tightSpacing) {
            AppIconView(bundlePath: source.path, icons: icons, size: DesignTokens.Metrics.sourceIconSize, glows: false)
            Text(source.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(-1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DesignTokens.Copy.copiedFrom(source.name))
    }

    @ViewBuilder
    private func content(row: ClipRowData, item: ClipboardItem, image: ClipImageLookup) -> some View {
        if item.contentType == .image {
            // Keyed and overlapped like the header, so one image fades into the next.
            ZStack {
                imageBody(image: image)
                    .id(item.id)
                    .transition(.opacity)
            }
        } else {
            PreviewTextView(
                itemID: item.id,
                content: item.content,
                matchedIndices: model.clips.matchedIndices(id: item.id),
                // The row's kind already applied the code rule to the clip's start; re-running it over
                // a 256 KiB clip on every model change would cost more than the rule is worth.
                isMonospaced: row.kind == .code,
                tint: DesignTokens.Palette.matchText,
                // The text view is AppKit and outside SwiftUI transitions, so it fades on its own clock,
                // matched to the header's.
                fadeDuration: reduceMotion ? DesignTokens.Motion.reducedFade : DesignTokens.Motion.previewFade
            )
        }
    }

    /// A decode failure shows a visible message, because an empty pane reads as "still loading". While the
    /// background decode runs the pane stays empty, which is what loading looks like.
    @ViewBuilder
    private func imageBody(image: ClipImageLookup) -> some View {
        switch image {
        case .pending:
            Color.clear
                .accessibilityHidden(true)
        case let .ready(image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.imageCornerRadius))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(DesignTokens.Identifier.previewImage)
                .accessibilityLabel(DesignTokens.Copy.previewLabel)
        case .unavailable:
            ContentUnavailableView(DesignTokens.Copy.imageUnavailable, systemImage: DesignTokens.Symbol.missingImage)
                .accessibilityIdentifier(DesignTokens.Identifier.previewImage)
        }
    }

    /// Characters for text and pixels for images, the two sizes a user can reason about.
    private func sizeDescription(item: ClipboardItem, image: ClipImageLookup) -> String {
        if item.contentType == .image {
            guard case let .ready(decoded) = image, let rep = decoded.representations.first else { return "" }
            return DesignTokens.Copy.pixelSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return DesignTokens.Copy.characterCount(counts.characters(in: item))
    }
}

/// Counts grapheme characters once per clip. Reference type so filling it during `body` is not a state
/// change; bounded so a long session cannot grow it without limit.
private final class CharacterCountMemo {
    private var counts: [UUID: Int] = [:]
    /// One entry per clip the history can hold, so the memo never evicts a count that is still reachable
    /// and cannot outgrow the history it describes.
    private static let limit = ClipboardHistoryLimits.itemCount

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
