import SwiftUI

/// One application result: icon, highlighted name, and a caption that tells same-named apps apart.
///
/// Equatable on its data and tint only, so typing re-renders the rows whose text changed instead of the
/// whole list. The icon cache arrives through the environment because it never changes for a given list.
struct AppRow: View, Equatable {
    let data: AppRowData
    let tint: Color

    @Environment(\.appIcons) private var icons

    var body: some View {
        HStack(spacing: DesignTokens.Metrics.inlineSpacing) {
            AppIconView(bundlePath: data.id, icons: icons)
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.rowTextSpacing) {
                HighlightedText(data.name, runs: data.runs, tint: tint, font: DesignTokens.Typography.rowTitle)
                if let caption {
                    Text(caption)
                        .font(DesignTokens.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Metrics.rowHorizontalPadding)
        .frame(height: DesignTokens.Layout.rowHeight)
    }

    /// The folder wins over the recent mark because telling two apps apart is the more urgent need.
    /// A match run means the user typed a query, so "Recent" would no longer explain the ordering.
    var caption: String? {
        if let location = data.location {
            return location
        }
        return data.isRecent && data.runs.isEmpty ? DesignTokens.Copy.recent : nil
    }

    static func == (lhs: AppRow, rhs: AppRow) -> Bool {
        lhs.data == rhs.data && lhs.tint == rhs.tint
    }
}

/// An app icon that redraws when the cache finishes loading it.
///
/// The cache hands out a placeholder first and loads the real icon off the main thread, so the view
/// listens for the load notification instead of polling.
private struct AppIconView: View {
    let bundlePath: String
    let icons: AppIconCache

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
        .frame(width: DesignTokens.Layout.iconSize, height: DesignTokens.Layout.iconSize)
        .id(loadCount)
        .onReceive(NotificationCenter.default.publisher(for: AppIconCache.didLoad)) { note in
            if note.userInfo?[AppIconCache.pathKey] as? String == bundlePath {
                loadCount += 1
            }
        }
        .accessibilityHidden(true)
    }
}
