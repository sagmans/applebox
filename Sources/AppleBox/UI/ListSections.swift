import Foundation

/// Which captioned group a row falls in on an empty query, so long lists read in chunks the user knows:
/// when they copied something, or whether they opened an app lately.
///
/// Pure functions of row data, kept apart from the views so grouping can never touch selection indices:
/// a header is drawn between rows and is not a row.
enum ListSections {
    /// Day bucket of a clip, newest first. Three buckets are enough because history is mostly recent and
    /// older clips are found by search, not by scrolling.
    private enum DayBucket {
        case today
        case yesterday
        case earlier

        init(_ date: Date, now: Date, calendar: Calendar) {
            if calendar.isDate(date, inSameDayAs: now) {
                self = .today
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(date, inSameDayAs: yesterday)
            {
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

    /// Caption of the group an app row belongs to.
    private static func title(for row: AppRowData) -> String {
        row.isRecent ? DesignTokens.Copy.recent : DesignTokens.Copy.applications
    }

    /// Header to draw above the app row at `index`, or nil when it continues the previous group.
    static func appHeader(in rows: [AppRowData], at index: Int) -> String? {
        guard rows.indices.contains(index) else { return nil }
        let current = title(for: rows[index])
        guard index > 0 else { return current }
        return title(for: rows[index - 1]) == current ? nil : current
    }

    /// Header to draw above the clip row at `index`, or nil when it continues the previous group.
    static func clipHeader(in rows: [ClipRowData], at index: Int, now: Date, calendar: Calendar) -> String? {
        guard rows.indices.contains(index) else { return nil }
        let current = DayBucket(rows[index].timestamp, now: now, calendar: calendar)
        guard index > 0 else { return current.title }
        return DayBucket(rows[index - 1].timestamp, now: now, calendar: calendar) == current ? nil : current.title
    }
}
