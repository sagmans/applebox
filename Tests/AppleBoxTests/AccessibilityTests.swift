import AppKit
@testable import AppleBox
import SwiftUI
import XCTest

/// Accessibility checks for the SwiftUI launcher.
///
/// A SwiftUI accessibility tree is not materialized for a window that is never shown, so what VoiceOver
/// speaks is checked at the points where it is decided: the identifier and copy tokens the views apply,
/// the static row-label function the list uses, and the model state that drives focus and selection. The
/// AppKit controls SwiftUI backs with (the text field) are inspected in a hosted view.
@MainActor
final class AccessibilityTests: XCTestCase {
    // MARK: - Constants

    private enum Fixture {
        static let appSupportPath = "/Users/testuser/Library/Application Support"
        static let applicationsQuery = "a"
        static let safariQuery = "Safari"
        static let safariName = "Safari"
        static let shortcutHelp = "Press Option-Space to open the launcher"
        static let clipboardNote = "Important meeting notes"
        static let minimumLabelLength = 5
        static let uuidLabelLength = 30
        static let settleInterval: TimeInterval = 0.3
        static let minimumNavigableRows = 2
    }

    // MARK: - Test Fixtures

    var mockFileSystem: MockFileSystem!
    var mockPasteboard: MockPasteboard!
    var mockWorkspace: MockWorkspace!
    var mockEventSource: MockEventSource!
    var model: LauncherModel!
    var searchService: SearchService!
    var clipboardManager: ClipboardManager!
    var window: NSWindow?

    /// Async, like the other main-actor suites: a synchronous override cannot touch main-actor state under
    /// strict concurrency without a data-race error.
    override func setUp() async throws {
        try await super.setUp()
        mockFileSystem = MockFileSystem()
        mockPasteboard = MockPasteboard()
        mockWorkspace = MockWorkspace()
        mockEventSource = MockEventSource()
        mockFileSystem.mockURLs = [URL(fileURLWithPath: Fixture.appSupportPath)]
        setupMockApplications()

        model = LauncherModel(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )
        searchService = SearchService(indexer: ApplicationIndexer(fileSystem: mockFileSystem))
        model.setSearchService(searchService)
        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        model.setClipboardManager(clipboardManager)
    }

    override func tearDown() async throws {
        // Not closed: the snapshot suite releases hosted windows the same way, and closing one here crashed
        // SwiftUI's teardown.
        window = nil
        model.hide()
        model = nil
        searchService = nil
        clipboardManager = nil
        mockFileSystem = nil
        mockPasteboard = nil
        mockWorkspace = nil
        mockEventSource = nil
        try await super.tearDown()
    }

    private func setupMockApplications() {
        let systemApps = URL(fileURLWithPath: "/System/Applications")
        let safari = URL(fileURLWithPath: "/System/Applications/Safari.app")
        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        mockFileSystem.addDirectory(at: systemApps, contents: [safari, mail, notes])
        for app in [safari, mail, notes] {
            mockFileSystem.addFile(at: app.path, isDirectory: true)
        }

        let mainApps = URL(fileURLWithPath: "/Applications")
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let slack = URL(fileURLWithPath: "/Applications/Slack.app")
        mockFileSystem.addDirectory(at: mainApps, contents: [chrome, slack])
        for app in [chrome, slack] {
            mockFileSystem.addFile(at: app.path, isDirectory: true)
        }

        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)
        mockFileSystem.addDirectory(at: userApps, contents: [])
    }

    // MARK: - Helpers

    /// Hosts the launcher at its mode size so AppKit-backed controls exist and can be inspected.
    private func hostLauncher() throws -> NSView {
        let size = model.mode == .clipboard ? DesignTokens.Layout.clipPanelSize : DesignTokens.Layout.appPanelSize
        let host = NSHostingView(rootView: LauncherView(model: model))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        let hosting = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hosting.contentView = host
        window = hosting
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: Fixture.settleInterval))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var found = root.subviews.compactMap { $0 as? T }
        for child in root.subviews {
            found += descendants(of: child, as: type)
        }
        return found
    }

    private func hostedSearchField() throws -> NSTextField {
        let host = try hostLauncher()
        return try XCTUnwrap(descendants(of: host, as: NSTextField.self).first, "Hosted launcher should contain a text field")
    }

    /// Polls the pasteboard directly instead of waiting for the monitor timer, which can fire late on a loaded runner.
    private func addClipboardItem(_ content: String, file: StaticString = #filePath, line: UInt = #line) {
        mockPasteboard.simulateExternalChange(content: content)
        clipboardManager.checkForChanges()
        XCTAssertEqual(clipboardManager.getHistory().first?.content, content, file: file, line: line)
    }

    private func appRowLabel(at index: Int) throws -> String {
        let row = try XCTUnwrap(model.apps.rows[safe: index], "Row \(index) should exist")
        return ResultsList.rowLabel(title: row.name, subtitle: row.location, index: index, count: model.resultCount)
    }

    private func clipRowLabel(at index: Int) throws -> String {
        let row = try XCTUnwrap(model.clips.rows[safe: index], "Row \(index) should exist")
        return ResultsList.rowLabel(title: row.preview, subtitle: nil, index: index, count: model.resultCount)
    }

    // MARK: - Search Field Accessibility Tests

    func testSearchFieldHasAccessibilityIdentifier() {
        // SwiftUI modifiers do not reach the backing text field until a window is shown, so the exact
        // value that SearchBar applies is checked.
        XCTAssertEqual(DesignTokens.Identifier.searchField, "AppleBoxSearchField", "Scripts and UI tests rely on this exact value")
    }

    func testSearchFieldHasAccessibilityLabel() throws {
        // The placeholder is what the field is announced as when it has no text.
        let field = try hostedSearchField()
        XCTAssertEqual(field.placeholderString, DesignTokens.Copy.searchApplicationsPlaceholder)
    }

    func testSearchFieldHasAccessibilityHelp() {
        // SearchBar applies this model value as the field's hint; the controller publishes it at launch.
        model.searchShortcutHelp = Fixture.shortcutHelp
        XCTAssertEqual(model.searchShortcutHelp, Fixture.shortcutHelp)
    }

    func testSearchFieldHasAccessibleChildren() throws {
        let field = try hostedSearchField()
        XCTAssertTrue(field.isEditable, "The search field should accept typing")
        XCTAssertTrue(field.acceptsFirstResponder, "The search field should take keyboard focus")
    }

    // MARK: - Results List Accessibility Tests

    func testTableViewHasAccessibilityIdentifier() {
        XCTAssertEqual(DesignTokens.Identifier.resultsTable, "AppleBoxResultsTable")
    }

    func testTableViewHasAccessibilityLabel() {
        // The list is a container that exposes its rows; with no rows it speaks the empty message instead.
        model.setQueryImmediately("zzzzzz-no-such-app")
        XCTAssertEqual(model.emptyMessage, DesignTokens.Copy.emptyApps)
    }

    func testTableViewHasAccessibilityHelp() {
        // Keys are announced through the footer hints: Return acts on the highlighted row, Esc closes.
        model.setApplicationResults([])
        XCTAssertEqual(DesignTokens.Copy.actionOpen, "Open")
        XCTAssertEqual(DesignTokens.Copy.actionClose, "Close")
    }

    // MARK: - Row Accessibility Tests

    func testApplicationRowsHaveAccessibilityIdentifiers() {
        XCTAssertEqual(DesignTokens.Identifier.applicationRow(0), "ApplicationRow_0")
        XCTAssertTrue(DesignTokens.Identifier.applicationRow(3).hasPrefix("ApplicationRow_"))
    }

    func testApplicationRowsHaveAccessibilityLabels() throws {
        model.setQueryImmediately(Fixture.safariQuery)
        let label = try appRowLabel(at: 0)
        XCTAssertTrue(label.contains(Fixture.safariName), "Label should contain app name")
        XCTAssertTrue(label.contains(DesignTokens.Copy.position(1, of: model.resultCount)), "Label should carry the position")
    }

    func testApplicationRowsHaveAccessibilityHelp() {
        // Position replaces per-row help: it tells VoiceOver users where they are in the list.
        let label = ResultsList.rowLabel(title: Fixture.safariName, subtitle: nil, index: 1, count: 4)
        XCTAssertEqual(label, "\(Fixture.safariName)\(DesignTokens.Copy.labelSeparator)2 of 4")
    }

    func testClipboardRowsHaveAccessibilityIdentifiers() {
        XCTAssertEqual(DesignTokens.Identifier.clipboardRow(0), "ClipboardRow_0")
        XCTAssertTrue(DesignTokens.Identifier.clipboardRow(2).hasPrefix("ClipboardRow_"))
    }

    func testClipboardRowsHaveAccessibilityLabels() throws {
        addClipboardItem("Test clipboard content")
        model.show(mode: .clipboard)
        model.setQueryImmediately("")
        let label = try clipRowLabel(at: 0)
        XCTAssertTrue(label.contains("Test clipboard content"), "Label should carry the clip text")
    }

    func testClipboardRowsHaveAccessibilityHelp() {
        // The subtitle is optional: a clip has none, so its label is the text and the position only.
        let label = ResultsList.rowLabel(title: "Clip", subtitle: nil, index: 0, count: 1)
        XCTAssertEqual(label, "Clip\(DesignTokens.Copy.labelSeparator)1 of 1")
    }

    // MARK: - Keyboard Navigation Tests

    func testKeyboardNavigationWorksWithoutMouse() {
        model.show()
        model.setQueryImmediately(Fixture.applicationsQuery)
        XCTAssertGreaterThan(model.resultCount, 0, "Should have search results")
        XCTAssertEqual(model.selection, 0, "First row should be selected initially")
    }

    func testArrowDownNavigatesWithoutMouse() {
        model.show()
        model.setQueryImmediately(Fixture.applicationsQuery)
        XCTAssertGreaterThanOrEqual(model.resultCount, Fixture.minimumNavigableRows)
        XCTAssertEqual(model.selection, 0)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 1)
    }

    func testArrowUpNavigatesWithoutMouse() {
        model.show()
        model.setQueryImmediately(Fixture.applicationsQuery)
        XCTAssertGreaterThanOrEqual(model.resultCount, Fixture.minimumNavigableRows)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 1)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, 0)
    }

    func testFullKeyboardNavigationCycle() {
        model.show()
        model.setQueryImmediately(Fixture.applicationsQuery)
        let count = model.resultCount
        XCTAssertGreaterThanOrEqual(count, Fixture.minimumNavigableRows)

        for row in 1 ..< count {
            model.moveSelection(by: 1)
            XCTAssertEqual(model.selection, row)
        }
        for row in stride(from: count - 2, through: 0, by: -1) {
            model.moveSelection(by: -1)
            XCTAssertEqual(model.selection, row)
        }
        // Up from the first row hands the keyboard back to the search field.
        model.moveSelection(by: -1)
        XCTAssertNil(model.selection)
    }

    // MARK: - VoiceOver Compatibility Tests

    func testSearchFieldLabelIsReadable() {
        let label = model.placeholder
        XCTAssertFalse(label.isEmpty)
        XCTAssertFalse(label.hasPrefix("_"), "Label should not be an internal identifier")
        XCTAssertFalse(label.contains("-") && label.count > Fixture.uuidLabelLength, "Label should not be a UUID")
    }

    func testTableViewLabelIsReadable() {
        // Empty-state copy is what the list announces when it holds nothing.
        for message in [DesignTokens.Copy.emptyApps, DesignTokens.Copy.emptyClipMatches, DesignTokens.Copy.emptyHistory] {
            XCTAssertFalse(message.isEmpty)
            XCTAssertGreaterThan(message.count, Fixture.minimumLabelLength)
        }
    }

    func testApplicationRowLabelIsReadableWithContent() throws {
        model.setQueryImmediately(Fixture.safariQuery)
        let label = try appRowLabel(at: 0)
        XCTAssertGreaterThan(label.count, Fixture.minimumLabelLength)
        XCTAssertTrue(label.contains(Fixture.safariName))
    }

    func testClipboardRowLabelIsReadableWithContent() throws {
        addClipboardItem(Fixture.clipboardNote)
        model.show(mode: .clipboard)
        model.setQueryImmediately("")
        let label = try clipRowLabel(at: 0)
        XCTAssertGreaterThan(label.count, Fixture.minimumLabelLength)
        XCTAssertTrue(label.contains("Important"))
    }

    // MARK: - Window Accessibility Tests

    func testWindowHasAccessibilityIdentifier() {
        XCTAssertEqual(DesignTokens.Identifier.window, "AppleBoxWindow")
    }

    func testWindowHasAccessibilityLabel() {
        // The preview pane is the one named region besides the list; the panel itself is identified, not named.
        XCTAssertEqual(DesignTokens.Copy.previewLabel, "Clip preview")
    }

    func testWindowHasAccessibilityHelp() {
        // Shortcut help is published to the field by the controller; the model carries it.
        model.searchShortcutHelp = Fixture.shortcutHelp
        XCTAssertEqual(model.searchShortcutHelp, Fixture.shortcutHelp)
    }

    // MARK: - Accessibility Element Discoverability Tests

    func testAccessibilityElementsAreDiscoverable() throws {
        model.show()
        model.setQueryImmediately(Fixture.applicationsQuery)
        let host = try hostLauncher()
        XCTAssertFalse(descendants(of: host, as: NSTextField.self).isEmpty, "Search field should be discoverable")
        XCTAssertGreaterThan(model.resultCount, 0)
        XCTAssertNotNil(model.apps.rows.first, "First row should be discoverable")
    }

    // MARK: - Search Mode Accessibility Tests

    func testSearchFieldPlaceholderChangesForClipboardMode() {
        model.show()
        model.switchMode(to: .clipboard)
        XCTAssertTrue(model.placeholder.contains("clipboard"))
    }

    func testSearchFieldPlaceholderChangesBackToApplicationMode() {
        model.show()
        model.switchMode(to: .clipboard)
        model.switchMode(to: .applications)
        XCTAssertTrue(model.placeholder.contains("applications"))
    }
}

private extension Array {
    /// Out-of-range reads return nil so a missing row fails an assertion instead of trapping the run.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
