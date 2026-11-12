import SwiftUI

/// One application result: icon, highlighted name, and a caption that tells same-named apps apart.
///
/// Equatable on its data and selection only, so typing re-renders the rows whose text changed instead of the
/// whole list. The icon cache arrives through the environment because it never changes for a given list.
struct AppRow: View, Equatable {
    let data: AppRowData
    let isSelected: Bool

    @Environment(\.appIcons) private var icons

    var body: some View {
        HStack(spacing: DesignTokens.Metrics.inlineSpacing) {
            AppIconView(bundlePath: data.id, icons: icons)
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.rowTextSpacing) {
                HighlightedText(data.name, runs: data.runs, isSelected: isSelected, font: DesignTokens.Typography.rowTitle)
                if let caption {
                    Text(caption)
                        .font(DesignTokens.Typography.rowSubtitle)
                        .foregroundStyle(RowSubtitle.style(isSelected: isSelected))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Metrics.rowHorizontalPadding)
        .frame(height: DesignTokens.Layout.rowHeight)
    }

    /// Only the folder, to tell same-named apps apart. "Recent" is a section header now, so repeating it
    /// on each row would be noise.
    var caption: String? {
        data.location
    }

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.data == rhs.data && lhs.isSelected == rhs.isSelected
    }
}

/// Subtitle color shared by app and clip rows. Secondary text on the darker selection capsule loses
/// contrast, so a selected row uses the label color, as `HighlightedText` does for its matches.
enum RowSubtitle {
    static func style(isSelected: Bool) -> HierarchicalShapeStyle {
        isSelected ? .primary : .secondary
    }
}

/// An app icon that redraws when the cache finishes loading it.
///
/// The cache hands out a placeholder first and loads the real icon off the main thread, so the view
/// listens for the load notification instead of polling.
struct AppIconView: View {
    let bundlePath: String
    let icons: AppIconCache
    /// Row icons use the full size and glow; the preview header reuses the view small and flat, so one
    /// view owns the placeholder-then-reload behavior.
    var size = DesignTokens.Layout.iconSize
    var glows = true

    /// Bumped on load notifications so the body re-reads the cache.
    @State private var loadCount = 0

    var body: some View {
        let icon = icons.icon(forBundlePath: bundlePath)
        // A placeholder has no representations; showing a symbol keeps the row from looking broken
        // while the real icon loads or if loading fails.
        Group {
            if icon.representations.isEmpty {
                Image(systemName: DesignTokens.Symbol.missingIcon)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        // The glow borrows the icon's own tone so each app has a soft identity color; absent until the
        // background average lands, which is why the view re-reads on the load notification.
        .shadow(
            color: (glows ? icons.averageColor(forBundlePath: bundlePath) : nil)?.opacity(DesignTokens.Palette.iconGlowOpacity) ?? .clear,
            radius: DesignTokens.Metrics.iconGlowRadius
        )
        .id(loadCount)
        .onReceive(NotificationCenter.default.publisher(for: AppIconCache.didLoad)) { note in
            if note.userInfo?[AppIconCache.pathKey] as? String == bundlePath {
                loadCount += 1
            }
        }
        .accessibilityHidden(true)
    }
}
