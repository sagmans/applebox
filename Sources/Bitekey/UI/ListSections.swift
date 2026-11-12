import Foundation

/// Which captioned group a row falls in on an empty query, so long lists read in chunks the user knows:
/// when they copied something, or whether they opened an app lately.
///
/// Pure functions of row data, kept apart from the views so grouping can never touch selection indices:
/// a header is drawn between rows and is not a row. Each function handles a whole list in one pass, so
/// the list derives its captions once per result set instead of per row on every redraw.
enum ListSections {
    /// Day bucket of a clip, newest first. Three buckets are enough because history is mostly recent and
    /// older clips are found by search, not by scrolling.
    private enum DayBucket {
        case today
        case yesterday
        case earlier

        /// `yesterday` is computed once by the caller, so a long list does not redo calendar math per row.
        init(_ date: Date, now: Date, yesterday: Date?, calendar: Calendar) {
            if calendar.isDate(date, inSameDayAs: now) {
                self = .today
            } else if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
                self = .yesterday
            } else {
                self = .earlier
            }
        }

        var title: String {
            switch self {
            case .today: DesignTokens.Copy.today
            case .yesterday: DesignTokens.Copy.yesterday
            case .earlier: DesignTokens.Copy.earlier
            }
        }
    }

    /// Caption to draw above each app row, or nil where the row continues the previous group.
    static func appHeaders(for rows: [AppRowData]) -> [String?] {
        headers(for: rows.map { $0.isRecent ? DesignTokens.Copy.recent : DesignTokens.Copy.applications })
    }

    /// Caption to draw above each clip row, or nil where the row continues the previous group.
    static func clipHeaders(for rows: [ClipRowData], now: Date, calendar: Calendar) -> [String?] {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        return headers(for: rows.map { DayBucket($0.timestamp, now: now, yesterday: yesterday, calendar: calendar).title })
    }

    /// A caption appears only where its group starts, since repeating it on every row would be noise.
    private static func headers(for titles: [String]) -> [String?] {
        titles.indices.map { index in
            index > 0 && titles[index - 1] == titles[index] ? nil : titles[index]
        }
    }
}
