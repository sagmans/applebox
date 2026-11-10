import AppKit
@testable import AppleBox
import XCTest

/// UI tests for search mode behavior.
/// Verifies application and clipboard modes are separated (no ">" trigger).
@MainActor
final class SearchModeSwitchingTests: XCTestCase {
    // MARK: - Test Fixtures

    var mockFileSystem: MockFileSystem!
    var mockPasteboard: MockPasteboard!
    var mockWorkspace: MockWorkspace!
    var mockEventSource: MockEventSource!
    var windowManager: WindowManager!
    var searchService: SearchService!
    var clipboardManager: ClipboardManager!

    override func setUp() async throws {
        try await super.setUp()

        mockFileSystem = MockFileSystem()
        mockPasteboard = MockPasteboard()
        mockWorkspace = MockWorkspace()
        mockEventSource = MockEventSource()

        // Configure mock file system with Application Support directory (needed for ClipboardManager)
        let appSupportURL = URL(fileURLWithPath: "/Users/testuser/Library/Application Support")
        mockFileSystem.mockURLs = [appSupportURL]

        setupMockApplications()

        windowManager = WindowManager(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        searchService = SearchService(indexer: indexer)
        windowManager.setSearchService(searchService)

        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        windowManager.setClipboardManager(clipboardManager)
    }

    override func tearDown() async throws {
        if windowManager.isVisible() {
            windowManager.hide()
        }
        windowManager = nil
        searchService = nil
        clipboardManager = nil
        mockFileSystem = nil
        mockPasteboard = nil
        mockWorkspace = nil
        mockEventSource = nil
        try await super.tearDown()
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

    /// Polls the pasteboard directly instead of waiting for the 0.5 s monitor
    /// timer, which can fire late on a loaded runner.
    private func addClipboardHistoryItem(_ content: String, file: StaticString = #filePath, line: UInt = #line) {
        mockPasteboard.simulateExternalChange(content: content)
        clipboardManager.checkForChanges()
        XCTAssertEqual(clipboardManager.getHistory().first?.content, content, file: file, line: line)
    }

    // MARK: - Application Mode

    func testShowDefaultsToApplicationsMode() {
        windowManager.show()
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search applications...")
    }

    func testTypingInApplicationsModeStaysInApplicationsMode() {
        windowManager.show()
        windowManager.simulateSearch(query: "Safari")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)
    }

    func testTypingGreaterThanInApplicationsModeDoesNotSwitchModes() {
        windowManager.show()
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)
    }

    func testApplicationsModeEmptyQueryShowsAllApplications() {
        windowManager.show()
        XCTAssertEqual(windowManager.getResultCount(), 4)
    }

    func testApplicationsModeOrdersByRecentApps() {
        let appSupportURL = mockFileSystem.mockURLs.first ?? mockFileSystem.mockHomeDirectory
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        try? mockFileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        let recentURL = appDirectory.appendingPathComponent("recent_applications.json")
        let recentPaths = [
            "/Applications/Slack.app",
            "/System/Applications/Safari.app",
        ]
        let data = try? JSONEncoder().encode(recentPaths)
        _ = mockFileSystem.createFile(atPath: recentURL.path, contents: data, attributes: nil)

        let freshWindowManager = WindowManager(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )
        defer {
            if freshWindowManager.isVisible() {
                freshWindowManager.hide()
            }
        }

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let freshSearchService = SearchService(indexer: indexer)
        freshWindowManager.setSearchService(freshSearchService)

        let freshClipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        freshWindowManager.setClipboardManager(freshClipboardManager)

        freshWindowManager.show()

        let cellView = freshWindowManager.getCellViewForTesting(at: 0)
        let firstName = (cellView?.viewWithTag(101) as? NSTextField)?.stringValue
        XCTAssertEqual(firstName, "Slack")
    }

    // MARK: - Clipboard Mode

    func testShowClipboardModeStartsInClipboardMode() {
        windowManager.show(mode: .clipboard)
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search clipboard history...")
    }

    func testTypingInClipboardModeStaysInClipboardMode() {
        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "Safari")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
    }

    func testClipboardModeEmptyQueryShowsAllHistory() {
        addClipboardHistoryItem("First item")
        addClipboardHistoryItem("Second item")
        addClipboardHistoryItem("Third item")

        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "")

        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        XCTAssertEqual(windowManager.getResultCount(), 3)
    }

    func testClipboardModeQueryFiltersHistory() {
        addClipboardHistoryItem("Hello World")
        addClipboardHistoryItem("Test Message")
        addClipboardHistoryItem("Hello Again")

        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "Hello")

        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        XCTAssertEqual(windowManager.getResultCount(), 2)
    }

    func testClipboardModeQueryIsCaseInsensitive() {
        addClipboardHistoryItem("HELLO WORLD")

        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "hello")

        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        XCTAssertGreaterThan(windowManager.getResultCount(), 0)
    }

    func testSearchTextPropertyReturnsCurrentValueInClipboardMode() {
        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "test")
        XCTAssertEqual(windowManager.getSearchText(), "test")
    }

    // MARK: - Mode Switching

    func testToggleSwitchesModesWithoutTypingTriggers() {
        windowManager.show()
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)

        windowManager.toggle(mode: .clipboard)
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)

        windowManager.toggle(mode: .applications)
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)
    }

    func testShowWithoutModeResetsToApplicationsMode() {
        windowManager.show(mode: .clipboard)
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        windowManager.hide()

        windowManager.show()
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)
    }
}
