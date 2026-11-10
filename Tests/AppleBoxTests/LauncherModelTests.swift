@testable import AppleBox
import XCTest

/// State-level tests for the launcher models, re-expressing the state assertions of the window tests
/// so they run without any AppKit view.
@MainActor
final class LauncherModelTests: XCTestCase {
    // MARK: - Test Fixtures

    var mockFileSystem: MockFileSystem!
    var mockPasteboard: MockPasteboard!
    var mockWorkspace: MockWorkspace!
    var mockEventSource: MockEventSource!
    var model: LauncherModel!
    var searchService: SearchService!
    var clipboardManager: ClipboardManager!

    override func setUp() async throws {
        try await super.setUp()

        mockFileSystem = MockFileSystem()
        mockPasteboard = MockPasteboard()
        mockWorkspace = MockWorkspace()
        mockEventSource = MockEventSource()

        // Application Support is needed by ClipboardManager and the recents store.
        mockFileSystem.mockURLs = [URL(fileURLWithPath: "/Users/testuser/Library/Application Support")]
        setupMockApplications()

        model = makeModel()
    }

    override func tearDown() async throws {
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

    private func makeModel() -> LauncherModel {
        let created = LauncherModel(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )
        searchService = SearchService(indexer: ApplicationIndexer(fileSystem: mockFileSystem))
        created.setSearchService(searchService)
        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        created.setClipboardManager(clipboardManager)
        return created
    }

    private func setupMockApplications() {
        let systemAppsURL = URL(fileURLWithPath: "/System/Applications")
        let safariApp = URL(fileURLWithPath: "/System/Applications/Safari.app")
        let mailApp = URL(fileURLWithPath: "/System/Applications/Mail.app")
        mockFileSystem.addDirectory(at: systemAppsURL, contents: [safariApp, mailApp])
        mockFileSystem.addFile(at: safariApp.path, isDirectory: true)
        mockFileSystem.addFile(at: mailApp.path, isDirectory: true)

        let mainAppsURL = URL(fileURLWithPath: "/Applications")
        let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let slackApp = URL(fileURLWithPath: "/Applications/Slack.app")
        mockFileSystem.addDirectory(at: mainAppsURL, contents: [chromeApp, slackApp])
        mockFileSystem.addFile(at: chromeApp.path, isDirectory: true)
        mockFileSystem.addFile(at: slackApp.path, isDirectory: true)

        let userAppsURL = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)
        mockFileSystem.addDirectory(at: userAppsURL, contents: [])
    }

    /// Polls the pasteboard directly instead of waiting for the monitor timer, which can fire late on a loaded runner.
    private func addClipboardHistoryItem(_ content: String, file: StaticString = #filePath, line: UInt = #line) {
        mockPasteboard.simulateExternalChange(content: content)
        clipboardManager.checkForChanges()
        XCTAssertEqual(clipboardManager.getHistory().first?.content, content, file: file, line: line)
    }

    /// Writes history to the mock store and loads it into a fresh manager, as the window tests did.
    private func seedClipboardHistory(_ items: [ClipboardItem]) throws {
        let appSupportURL = try XCTUnwrap(mockFileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let storageURL = appSupportURL
            .appendingPathComponent("AppleBox", isDirectory: true)
            .appendingPathComponent("clipboard_history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        _ = try mockFileSystem.createFile(atPath: storageURL.path, contents: encoder.encode(items), attributes: nil)

        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        model.setClipboardManager(clipboardManager)
    }

    // MARK: - Application Mode

    func testShowDefaultsToApplicationsMode() {
        model.show()
        XCTAssertEqual(model.mode, .applications)
        XCTAssertEqual(model.placeholder, "Search applications...")
    }

    func testTypingInApplicationsModeStaysInApplicationsMode() {
        model.show()
        model.setQueryImmediately("Safari")
        XCTAssertEqual(model.mode, .applications)
    }

    func testTypingGreaterThanInApplicationsModeDoesNotSwitchModes() {
        model.show()
        model.setQueryImmediately(">")
        XCTAssertEqual(model.mode, .applications)
    }

    func testApplicationsModeEmptyQueryShowsAllApplications() {
        model.show()
        XCTAssertEqual(model.resultCount, 4)
    }

    func testApplicationsModeOrdersByRecentApps() throws {
        let appSupportURL = mockFileSystem.mockURLs.first ?? mockFileSystem.mockHomeDirectory
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        try? mockFileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        let recentURL = appDirectory.appendingPathComponent("recent_applications.json")
        let recentPaths = [
            "/Applications/Slack.app",
            "/System/Applications/Safari.app",
        ]
        _ = try mockFileSystem.createFile(atPath: recentURL.path, contents: JSONEncoder().encode(recentPaths), attributes: nil)

        let freshModel = makeModel()
        defer { freshModel.hide() }
        freshModel.show()

        XCTAssertEqual(freshModel.apps.rows.first?.name, "Slack")
    }

    // MARK: - Clipboard Mode

    func testShowClipboardModeStartsInClipboardMode() {
        model.show(mode: .clipboard)
        XCTAssertEqual(model.mode, .clipboard)
        XCTAssertEqual(model.placeholder, "Search clipboard history...")
    }

    func testTypingInClipboardModeStaysInClipboardMode() {
        model.show(mode: .clipboard)
        model.setQueryImmediately("Safari")
        XCTAssertEqual(model.mode, .clipboard)
    }

    func testClipboardModeEmptyQueryShowsAllHistory() {
        addClipboardHistoryItem("First item")
        addClipboardHistoryItem("Second item")
        addClipboardHistoryItem("Third item")

        model.show(mode: .clipboard)
        model.setQueryImmediately("")

        XCTAssertEqual(model.mode, .clipboard)
        XCTAssertEqual(model.resultCount, 3)
    }

    func testClipboardModeQueryFiltersHistory() {
        addClipboardHistoryItem("Hello World")
        addClipboardHistoryItem("Test Message")
        addClipboardHistoryItem("Hello Again")

        model.show(mode: .clipboard)
        model.setQueryImmediately("Hello")

        XCTAssertEqual(model.mode, .clipboard)
        XCTAssertEqual(model.resultCount, 2)
    }

    func testClipboardModeQueryIsCaseInsensitive() {
        addClipboardHistoryItem("HELLO WORLD")

        model.show(mode: .clipboard)
        model.setQueryImmediately("hello")

        XCTAssertEqual(model.mode, .clipboard)
        XCTAssertGreaterThan(model.resultCount, 0)
    }

    func testQueryPropertyReturnsCurrentValueInClipboardMode() {
        model.show(mode: .clipboard)
        model.setQueryImmediately("test")
        XCTAssertEqual(model.query, "test")
    }

    // MARK: - Mode Switching

    func testSwitchModeSwitchesModesWithoutTypingTriggers() {
        model.show()
        XCTAssertEqual(model.mode, .applications)

        model.switchMode(to: .clipboard)
        XCTAssertEqual(model.mode, .clipboard)

        model.switchMode(to: .applications)
        XCTAssertEqual(model.mode, .applications)
    }

    func testShowWithoutModeResetsToApplicationsMode() {
        model.show(mode: .clipboard)
        XCTAssertEqual(model.mode, .clipboard)
        model.hide()

        model.show()
        XCTAssertEqual(model.mode, .applications)
    }

    // MARK: - Presentation

    func testPresentationFollowsShowAndHide() {
        XCTAssertFalse(model.isPresented, "A new launcher starts closed")

        model.show()
        XCTAssertTrue(model.isPresented)
        model.show()
        XCTAssertTrue(model.isPresented, "A second show keeps the launcher open")

        model.hide()
        XCTAssertFalse(model.isPresented)
        model.hide()
        XCTAssertFalse(model.isPresented, "A second hide keeps the launcher closed")
    }

    func testShowClearsQueryFromPreviousSession() {
        model.show()
        model.setQueryImmediately("Safari")
        model.hide()

        model.show()

        XCTAssertEqual(model.query, "")
    }

    func testShowDoesNotTouchTheClipboard() {
        model.show(mode: .clipboard)

        XCTAssertEqual(mockPasteboard.clearContentsCalls, 0)
        XCTAssertEqual(mockPasteboard.setStringCalls.count, 0)
    }

    func testCopySelectionDismissesTheLauncher() throws {
        try seedClipboardHistory([ClipboardItem(content: "hello")])
        var dismissCount = 0
        model.onDismiss = { dismissCount += 1 }
        model.show(mode: .clipboard)

        XCTAssertTrue(model.copySelection())

        XCTAssertEqual(dismissCount, 1)
    }

    func testControllerToggleOpensAndClosesTheLauncher() {
        let controller = LauncherController(model: model)
        defer { controller.panel.orderOut(nil) }
        XCTAssertFalse(controller.isVisible)

        for _ in 0 ..< 2 {
            controller.toggle(mode: nil)
            XCTAssertTrue(controller.isVisible, "Toggle while closed should open")
            XCTAssertTrue(model.isPresented)

            controller.toggle(mode: nil)
            XCTAssertFalse(controller.isVisible, "Toggle while open should close")
            XCTAssertFalse(model.isPresented)
        }
    }

    // MARK: - Escape

    func testEscapeWithTextClearsSelectionAndDismisses() throws {
        try seedClipboardHistory([ClipboardItem(content: "hello")])

        var dismissCount = 0
        model.onDismiss = { dismissCount += 1 }
        model.show(mode: .clipboard)
        XCTAssertEqual(model.selection, 0)

        model.query = "abc"
        model.escape()

        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.selection)
        XCTAssertEqual(dismissCount, 1)
    }

    func testEscapeWithEmptyTextDismisses() {
        var dismissCount = 0
        model.onDismiss = { dismissCount += 1 }
        model.show()
        XCTAssertEqual(model.query, "")

        model.escape()

        XCTAssertEqual(dismissCount, 1)
    }

    // MARK: - Exact Substring Highlight

    func testExactSubstringHighlightInClipboardSearch() throws {
        try seedClipboardHistory([
            ClipboardItem(content: "[13:52:52] [~/source/me/dotf][main] (~6, ?1)"),
            // Contains every character of "[main]" but scattered, so it must rank below the exact match.
            ClipboardItem(content: "[log] message about interesting news]"),
        ])

        model.show(mode: .clipboard)
        model.setQueryImmediately("[main]")

        XCTAssertEqual(model.resultCount, 2, "Both items should match")
        let first = try XCTUnwrap(model.clips.rows.first)
        XCTAssertTrue(first.preview.contains("[main]"), "Row 0 should display item containing exact '[main]'")
        XCTAssertFalse(first.runs.isEmpty, "Row should carry highlight runs for matched characters")
    }

    func testHighlightedIndicesAreContiguousForExactSubstring() throws {
        try seedClipboardHistory([ClipboardItem(content: "test [main] string")])

        model.show(mode: .clipboard)
        model.setQueryImmediately("[main]")

        let results = clipboardManager.searchHistoryWithMatches(query: "[main]")
        XCTAssertEqual(results.count, 1)

        let indices = results[0].matchedIndices
        XCTAssertEqual(indices.count, 6, "Should have 6 indices for '[main]'")
        for i in 1 ..< indices.count {
            XCTAssertEqual(indices[i], indices[i - 1] + 1, "Indices should be contiguous for exact substring")
        }

        let content = results[0].item.content
        let startIdx = try content.index(content.startIndex, offsetBy: XCTUnwrap(indices.first))
        let endIdx = try content.index(content.startIndex, offsetBy: XCTUnwrap(indices.last) + 1)
        XCTAssertEqual(String(content[startIdx ..< endIdx]), "[main]")

        // The row must highlight exactly the same span.
        let row = try XCTUnwrap(model.clips.rows.first)
        XCTAssertEqual(row.runs.map { String(row.preview[$0.range]) }, ["[main]"])
    }

    // MARK: - Panel Key Routing

    private func keyEvent(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    func testPanelEscapeWithTextClearsSelectionAndDismisses() throws {
        try seedClipboardHistory([ClipboardItem(content: "hello")])
        let controller = LauncherController(model: model)
        model.show(mode: .clipboard)
        XCTAssertEqual(model.selection, 0)
        model.query = "abc"

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.escape))

        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isPresented)
    }

    func testPanelEscapeWithEmptyTextDismisses() throws {
        let controller = LauncherController(model: model)
        model.show()
        XCTAssertEqual(model.query, "")

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.escape))

        XCTAssertFalse(model.isPresented)
    }

    func testPanelArrowKeysNavigateSelection() throws {
        try seedClipboardHistory([ClipboardItem(content: "one"), ClipboardItem(content: "two")])
        let controller = LauncherController(model: model)
        model.show(mode: .clipboard)
        XCTAssertEqual(model.selection, 0)

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.downArrow))
        XCTAssertEqual(model.selection, 1)

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.upArrow))
        XCTAssertEqual(model.selection, 0)
    }

    func testPanelReturnActivatesSelection() throws {
        try seedClipboardHistory([ClipboardItem(content: "hello")])
        let controller = LauncherController(model: model)
        model.show(mode: .clipboard)

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.returnKey, characters: "\r"))

        XCTAssertEqual(mockPasteboard.string(forType: .string), "hello")
    }

    func testPanelOptionReturnCopiesClip() throws {
        try seedClipboardHistory([ClipboardItem(content: "hello")])
        let controller = LauncherController(model: model)
        model.show(mode: .clipboard)

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.returnKey, characters: "\r", modifiers: .option))

        XCTAssertEqual(mockPasteboard.string(forType: .string), "hello")
        XCTAssertTrue(mockEventSource.pasteTargets.isEmpty, "Copy must not paste")
    }

    func testPanelLeavesReservedKeysToInputMethodWhileComposing() throws {
        let controller = LauncherController(model: model)
        model.show()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        container.addSubview(textView)
        controller.panel.contentView = container
        XCTAssertTrue(controller.panel.makeFirstResponder(textView))
        textView.setMarkedText("あ", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())

        try controller.panel.sendEvent(keyEvent(LauncherKeyCode.escape))

        XCTAssertTrue(model.isPresented, "Esc must reach the input method, not dismiss the launcher")
    }
}
