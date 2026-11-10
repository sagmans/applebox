import AppKit
@testable import AppleBox
import SwiftUI
import XCTest

/// Accessibility checks for the SwiftUI launcher.
///
/// A SwiftUI accessibility tree is not materialized without a connected assistive client. Experiment
/// (fix round 1): a borderless window was ordered in off screen (origin -20000, -20000, never key) and the
/// hosting view's accessibility children were walked until the rows had been laid out, through both the
/// modern and the legacy attribute. Only two AppKit elements ever appeared: a text field (no identifier,
/// label or help) and a scroll area (also none). No SwiftUI row, container, button or preview element
/// appeared, so the modifiers SwiftUI applies cannot be read back in a test. Cases that would only compare
/// a constant with itself were deleted. What remains checks real behavior: the row label and hint the list
/// builds (static, shared with the views), the panel's own AppKit label and help, the AppKit elements
/// SwiftUI backs with, and the keyboard model. VoiceOver output itself needs a manual pass.
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
        static let settleTimeout: TimeInterval = 5
        static let pollInterval: TimeInterval = 0.05
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
        // Waits for the hosted field instead of sleeping: it appears once SwiftUI has finished its first pass.
        let deadline = Date(timeIntervalSinceNow: Fixture.settleTimeout)
        while Date() < deadline, descendants(of: host, as: NSTextField.self).isEmpty {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Fixture.pollInterval))
        }
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

    func testSearchFieldHasAccessibilityLabel() throws {
        // The placeholder is what the field is announced as when it has no text.
        let field = try hostedSearchField()
        XCTAssertEqual(field.placeholderString, DesignTokens.Copy.searchApplicationsPlaceholder)
    }

    func testSearchFieldHasAccessibleChildren() throws {
        let field = try hostedSearchField()
        XCTAssertTrue(field.isEditable, "The search field should accept typing")
        XCTAssertTrue(field.acceptsFirstResponder, "The search field should take keyboard focus")
    }

    // MARK: - Results List Accessibility Tests

    // MARK: - Row Accessibility Tests

    func testApplicationRowsHaveAccessibilityLabels() throws {
        model.setQueryImmediately(Fixture.safariQuery)
        let label = try appRowLabel(at: 0)
        XCTAssertTrue(label.contains(Fixture.safariName), "Label should contain app name")
        XCTAssertTrue(label.contains(DesignTokens.Copy.position(1, of: model.resultCount)), "Label should carry the position")
    }

    func testApplicationRowsHaveAccessibilityHelp() {
        let hint = ResultsList.rowHint(for: .applications)
        XCTAssertEqual(hint, DesignTokens.Copy.applicationRowHint)
        XCTAssertTrue(hint.contains("launch"), "Hint should mention launching the application")
    }

    func testClipboardRowsHaveAccessibilityLabels() throws {
        addClipboardItem("Test clipboard content")
        model.show(mode: .clipboard)
        model.setQueryImmediately("")
        let label = try clipRowLabel(at: 0)
        XCTAssertTrue(label.contains("Test clipboard content"), "Label should carry the clip text")
    }

    func testClipboardRowsHaveAccessibilityHelp() {
        let hint = ResultsList.rowHint(for: .clipboard)
        XCTAssertEqual(hint, DesignTokens.Copy.clipRowHint)
        XCTAssertTrue(hint.contains("copy"), "Hint should mention copying to the clipboard")
        XCTAssertNotEqual(hint, ResultsList.rowHint(for: .applications), "Each list needs its own hint")
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
        XCTAssertEqual(LauncherController(model: model).panel.accessibilityIdentifier(), DesignTokens.Identifier.window)
    }

    func testWindowHasAccessibilityLabel() throws {
        let label = try XCTUnwrap(LauncherController(model: model).panel.accessibilityLabel())
        XCTAssertTrue(label.contains("AppleBox"), "Window label should mention AppleBox")
    }

    func testWindowHasAccessibilityHelp() throws {
        let help = try XCTUnwrap(LauncherController(model: model).panel.accessibilityHelp())
        XCTAssertTrue(help.contains("launcher"), "Help should describe the purpose")
    }

    // MARK: - Accessibility Element Discoverability Tests

    func testAccessibilityElementsAreDiscoverable() throws {
        model.show()
        model.setQueryImmediately(Fixture.applicationsQuery)
        let host = try hostLauncher()
        let roles = Set((host.accessibilityAttributeValue(.children) as? [NSAccessibilityProtocol] ?? []).compactMap { $0.accessibilityRole() })
        XCTAssertTrue(roles.contains(.textField), "Search field should be discoverable")
        XCTAssertTrue(roles.contains(.scrollArea), "Results list should be discoverable")
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
