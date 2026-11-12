import AppKit
@testable import Bitekey
import SnapshotTesting
import SwiftUI
import XCTest

/// Snapshot tests for the glass launcher views, to catch visual regressions.
///
/// The views render with `launcherSnapshotMode`, which swaps every glass surface for a fixed background:
/// glass samples what is behind it and follows the display profile, so references with real glass never
/// matched from one machine to the next (ASG-1279). The test therefore covers layout, text, selection and
/// colors of the content, not the glass material itself.
///
/// There is no Increase Contrast or Reduce Transparency variant. The launcher has no contrast-specific
/// code: the system glass handles both settings, and a test cannot force either one (the contrast
/// environment value is read-only, and a high-contrast appearance on the hosting view changes nothing
/// SwiftUI reads: a recorded variant came out byte-identical to the dark reference).
@MainActor
final class SnapshotTests: XCTestCase {
    // MARK: - Constants

    private enum Fixture {
        /// Fake application support folder; nothing is read from or written to the real one.
        static let appSupportPath = "/Users/test/Library/Application Support"
        /// Fixed copy times, so the preview header never depends on the day the test runs.
        static let copyTimes = [
            "2026-05-28T08:00:00Z",
            "2026-05-27T22:50:00Z",
            "2026-04-09T07:15:00Z",
            "2026-03-21T18:45:00Z",
            "2026-02-03T14:05:00Z",
            "2026-01-15T09:30:00Z",
        ]
        /// Fixed "now" for relative times and day sections: after the newest copy time, so the list shows
        /// Today, Yesterday and Earlier whenever the suite runs.
        static let referenceTime = "2026-05-28T12:00:00Z"
        /// Pinned so the date format in the header renders the same wherever the suite runs.
        static let localeIdentifier = "en_US"
        static let timeZoneIdentifier = "UTC"
        static let manyApplicationCount = 15
        static let iconSide: CGFloat = 32
        static let iconRed: CGFloat = 0.25
        static let iconGreen: CGFloat = 0.55
        static let iconBlue: CGFloat = 0.95
        static let iconAlpha: CGFloat = 1
        static let highlightQuery = "total"
        static let codeClip = """
        func calculateTotal(items: [Item]) -> Double {
            var total = 0.0
            for item in items {
                total += item.price * Double(item.quantity)
            }
            return total
        }
        """
        static let clipTexts = [
            "Hello, World!",
            "https://example.com/path/to/resource",
            "Some longer text that might appear in clipboard history that the user copied recently.",
            "{ \"key\": \"value\", \"number\": 42 }",
            "user@example.com",
            // A color clip, so the references cover the swatch in a row.
            "#C8502A",
        ]
        static let applicationNames = ["Safari", "Mail", "Notes", "Calendar", "Reminders"]
    }

    private enum Look: String, CaseIterable {
        case dark
        case light

        var appearanceName: NSAppearance.Name {
            self == .dark ? .darkAqua : .aqua
        }
    }

    /// Matching tolerance of the references: loose enough for anti-aliasing noise, tight enough that a
    /// moved row or a lost highlight fails.
    private static let precision: Float = 0.99
    private static let perceptualPrecision: Float = 0.98
    /// Longest a render may take to reach a stable image before the test fails instead of recording a
    /// half-laid-out one.
    private static let settleTimeout: TimeInterval = 5
    /// Gap between two looks at the rendered image while waiting for it to stop changing.
    private static let settlePollInterval: TimeInterval = 0.05
    /// Consecutive identical looks that count as settled, so one pause between two animation frames
    /// does not end the wait early.
    private static let settleStableLooks = 3

    private var shouldRecordSnapshots: Bool {
        let value = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"]
        return value == "1" || value == "true"
    }

    /// Records when asked to; otherwise nil keeps the library default of comparing against references.
    private var recordMode: SnapshotTestingConfiguration.Record? {
        shouldRecordSnapshots ? .all : nil
    }

    private struct SnapshotIconProvider: AppIconProviding {
        func icon(forBundlePath _: String) -> NSImage {
            let size = NSSize(width: Fixture.iconSide, height: Fixture.iconSide)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(
                srgbRed: Fixture.iconRed,
                green: Fixture.iconGreen,
                blue: Fixture.iconBlue,
                alpha: Fixture.iconAlpha
            ).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
            return image
        }
    }

    /// Encodes only what the history file stores, so a fixed copy time can be decoded back; the item type
    /// stamps the current time on creation and offers no other way in.
    private struct StoredClip: Encodable {
        let content: String
        let timestamp: Date
        let contentType = "text"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Skip in CI - snapshot rendering differs between environments (fonts, antialiasing, etc.)
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] == "true",
            "Snapshot tests are skipped in CI due to environment-specific rendering differences."
        )
    }

    // MARK: - Fixtures

    private func makeModel() -> LauncherModel {
        let fileSystem = MockFileSystem()
        fileSystem.mockURLs = [URL(fileURLWithPath: Fixture.appSupportPath)]
        return LauncherModel(
            workspace: MockWorkspace(),
            pasteboard: MockPasteboard(),
            eventSource: MockEventSource(),
            fileSystem: fileSystem
        )
    }

    private func applicationResults(count: Int? = nil) -> [SearchResult] {
        let applications: [ApplicationInfo] = if let count {
            (1 ... count).map { ApplicationInfo(name: "Application \($0)", bundlePath: "/Applications/App\($0).app") }
        } else {
            Fixture.applicationNames.map { ApplicationInfo(name: $0, bundlePath: "/Applications/\($0).app") }
        }
        return applications.enumerated().map { index, application in
            SearchResult(application: application, score: 100 - index * 10, matchedIndices: [])
        }
    }

    /// Builds a clip with a fixed copy time by decoding what the history file would hold.
    private func clip(_ content: String, copiedAt isoTime: String) throws -> ClipboardItem {
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: isoTime))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClipboardItem.self, from: encoder.encode(StoredClip(content: content, timestamp: date)))
    }

    /// Matches with fixed copy times. They go straight to the model because the history drops clips older
    /// than its retention window, which would make any fixed date expire.
    private func clipMatches(_ texts: [String] = Fixture.clipTexts, query: String = "") throws -> [ClipboardManager.ClipboardSearchMatch] {
        try texts.enumerated().map { index, text in
            let item = try clip(text, copiedAt: Fixture.copyTimes[index % Fixture.copyTimes.count])
            let match = query.isEmpty ? nil : FuzzyMatcher.matchWithIndices(query: query, candidate: text)
            return ClipboardManager.ClipboardSearchMatch(
                item: item,
                score: match?.score ?? 0,
                matchedIndices: match?.matchedIndices ?? []
            )
        }
    }

    // MARK: - Rendering

    /// Hosts the launcher at its mode size with an explicit frame, because an unsized hosting view
    /// renders as zero-size and the references would be empty. Returns the window, which the caller must
    /// keep alive: a view does not retain the window that holds it.
    private func hostLauncher(model: LauncherModel, look: Look) throws -> NSWindow {
        let size = model.mode == .clipboard ? DesignTokens.Layout.clipPanelSize : DesignTokens.Layout.appPanelSize
        let root = try LauncherView(model: model)
            .environment(\.launcherSnapshotMode, true)
            .environment(\.appIcons, AppIconCache(loader: SnapshotIconProvider()))
            .environment(\.referenceDate, ISO8601DateFormatter().date(from: Fixture.referenceTime))
            .environment(\.locale, Locale(identifier: Fixture.localeIdentifier))
            .environment(\.timeZone, XCTUnwrap(TimeZone(identifier: Fixture.timeZoneIdentifier)))
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: look.appearanceName)

        // A display profile is a property of the host machine, so the window pins standard RGB. The window
        // is never shown; the caller keeps it alive for the length of the render.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .sRGB
        window.contentView = host
        return window
    }

    /// Waits until the rendered image stops changing, which is when lazy rows, the AppKit-backed field
    /// and the selection motion have finished; a fixed delay would be too short on a loaded machine and
    /// wasted time on a fast one.
    private func settle(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: Self.settleTimeout)
        var previous: Data?
        var stableLooks = 0
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.settlePollInterval))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let current = rep.representation(using: .tiff, properties: [:])
            stableLooks = current == previous ? stableLooks + 1 : 0
            previous = current
            if stableLooks >= Self.settleStableLooks {
                return
            }
        }
        XCTFail("The launcher did not reach a stable image within \(Self.settleTimeout) s", file: file, line: line)
    }

    /// Renders one scenario for `look` and returns the window whose content view is the settled launcher.
    ///
    /// The search field reports its own empty text back to the model while it first appears, and in
    /// clipboard mode that search would replace fixture rows with an empty history. The view therefore
    /// renders first and `arrange` runs after that has settled, so the fixture is the last write.
    private func renderScenario(
        mode: SearchMode,
        look: Look,
        arrange: (LauncherModel) throws -> Void
    ) throws -> NSWindow {
        let model = makeModel()
        model.switchMode(to: mode)
        let window = try hostLauncher(model: model, look: look)
        let view = try XCTUnwrap(window.contentView)
        settle(view)
        try arrange(model)
        settle(view)
        return window
    }

    /// Snapshots a scenario in dark and light, naming each so a failure says which look broke.
    private func assertLauncher(
        _ mode: SearchMode,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line,
        arrange: (LauncherModel) throws -> Void = { _ in }
    ) throws {
        for look in Look.allCases {
            let window = try renderScenario(mode: mode, look: look, arrange: arrange)
            try assertSnapshot(
                of: XCTUnwrap(window.contentView),
                as: .image(precision: Self.precision, perceptualPrecision: Self.perceptualPrecision),
                named: look.rawValue,
                record: recordMode,
                file: file,
                testName: testName,
                line: line
            )
        }
    }

    // MARK: - Snapshot Tests for Empty State

    func testSnapshotEmptySearchState() throws {
        try assertLauncher(.applications)
    }

    // MARK: - Snapshot Tests for Populated Search Results

    func testSnapshotPopulatedSearchResults() throws {
        try assertLauncher(.applications) { $0.setApplicationResults(applicationResults()) }
    }

    // MARK: - Snapshot Tests for Clipboard Mode Results

    func testSnapshotClipboardModeResults() throws {
        try assertLauncher(.clipboard) { try $0.setClipboardMatches(clipMatches()) }
    }

    // MARK: - Snapshot Tests for Selected Row Highlighting

    func testSnapshotSelectedRowHighlighting() throws {
        try assertLauncher(.applications) {
            $0.setApplicationResults(applicationResults())
            $0.select(2)
        }
    }

    // MARK: - Additional Snapshot Tests

    func testSnapshotClipboardModeWithSelection() throws {
        try assertLauncher(.clipboard) {
            try $0.setClipboardMatches(clipMatches())
            $0.select(1)
        }
    }

    func testSnapshotManySearchResults() throws {
        // More rows than fit, so the list scrolls; the scroll bar is an overlay in the views and cannot
        // take width, which keeps the reference independent of the "Show scroll bars" setting.
        try assertLauncher(.applications) { $0.setApplicationResults(applicationResults(count: Fixture.manyApplicationCount)) }
    }

    /// Same scene as PopulatedSearchResults, because that one leaves row 0 selected by default; kept for
    /// parity with the old suite, which had both cases.
    func testSnapshotFirstRowSelected() throws {
        try assertLauncher(.applications) {
            $0.setApplicationResults(applicationResults())
            $0.select(0)
        }
    }

    func testSnapshotLastRowSelected() throws {
        let results = applicationResults()
        try assertLauncher(.applications) {
            $0.setApplicationResults(results)
            $0.select(results.count - 1)
        }
    }

    // MARK: - Clip Preview Snapshot Tests

    func testSnapshotClipPreview() throws {
        // A multi-line code clip exercises the monospaced preview with the header's kind, time and size.
        try assertLauncher(.clipboard) { try $0.setClipboardMatches(clipMatches([Fixture.codeClip])) }
    }

    func testSnapshotClipPreviewWithHighlightedMatches() throws {
        // The query stays out of the field: the field echoes its text back as a search, which would
        // replace these fixture rows. The highlights come from the matches themselves.
        try assertLauncher(.clipboard) {
            try $0.setClipboardMatches(clipMatches([Fixture.codeClip], query: Fixture.highlightQuery), query: Fixture.highlightQuery)
        }
    }
}
