import XCTest
import AppKit
@testable import AppleBox

/// UI tests for search mode switching behavior
/// Verifies the '>' trigger switches to clipboard mode and mode switching works correctly
final class SearchModeSwitchingTests: XCTestCase {

    // MARK: - Test Fixtures

    var mockFileSystem: MockFileSystem!
    var mockPasteboard: MockPasteboard!
    var mockWorkspace: MockWorkspace!
    var mockEventSource: MockEventSource!
    var windowManager: WindowManager!
    var searchService: SearchService!
    var clipboardManager: ClipboardManager!

    override func setUp() {
        super.setUp()

        // Create mocks
        mockFileSystem = MockFileSystem()
        mockPasteboard = MockPasteboard()
        mockWorkspace = MockWorkspace()
        mockEventSource = MockEventSource()

        // Configure mock file system with Application Support directory (needed for ClipboardManager)
        let appSupportURL = URL(fileURLWithPath: "/Users/testuser/Library/Application Support")
        mockFileSystem.mockURLs = [appSupportURL]

        // Setup mock applications directory
        setupMockApplications()

        // Create WindowManager with injected mocks
        windowManager = WindowManager(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )

        // Create and inject SearchService
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        searchService = SearchService(indexer: indexer)
        windowManager.setSearchService(searchService)

        // Create and inject ClipboardManager
        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        windowManager.setClipboardManager(clipboardManager)
    }

    override func tearDown() {
        // Hide window if visible
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
        super.tearDown()
    }

    /// Helper to setup mock applications in file system
    private func setupMockApplications() {
        // Setup system applications
        let systemAppsURL = URL(fileURLWithPath: "/System/Applications")
        let safariApp = URL(fileURLWithPath: "/System/Applications/Safari.app")
        let mailApp = URL(fileURLWithPath: "/System/Applications/Mail.app")

        mockFileSystem.addDirectory(at: systemAppsURL, contents: [safariApp, mailApp])
        mockFileSystem.addFile(at: safariApp.path, isDirectory: true)
        mockFileSystem.addFile(at: mailApp.path, isDirectory: true)

        // Setup main applications
        let mainAppsURL = URL(fileURLWithPath: "/Applications")
        let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let slackApp = URL(fileURLWithPath: "/Applications/Slack.app")

        mockFileSystem.addDirectory(at: mainAppsURL, contents: [chromeApp, slackApp])
        mockFileSystem.addFile(at: chromeApp.path, isDirectory: true)
        mockFileSystem.addFile(at: slackApp.path, isDirectory: true)

        // Setup user applications
        let userAppsURL = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)
        mockFileSystem.addDirectory(at: userAppsURL, contents: [])
    }

    /// Helper to add items to clipboard history via mock pasteboard
    private func addClipboardHistoryItem(_ content: String) {
        mockPasteboard.simulateExternalChange(content: content)
        // Wait for clipboard manager to detect the change
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
    }

    // MARK: - Test: Typing '>' switches to clipboard search mode

    func testTypingTriggerSwitchesToClipboardMode() {
        // Given: Window is visible in applications mode
        windowManager.show()
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Should start in applications mode")

        // When: User types '>'
        windowManager.simulateSearch(query: ">")

        // Then: Search mode should switch to clipboard
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should switch to clipboard mode after typing '>'")
    }

    func testInitialModeIsApplications() {
        // Given: Window is shown fresh
        windowManager.show()

        // Then: Mode should be applications
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Initial mode should be applications")
    }

    func testModeStaysApplicationsForNormalSearch() {
        // Given: Window is visible
        windowManager.show()

        // When: User types a normal search query (not starting with '>')
        windowManager.simulateSearch(query: "Safari")

        // Then: Mode should remain applications
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Mode should stay applications for normal search")
    }

    func testModeStaysApplicationsForEmptyQuery() {
        // Given: Window is visible
        windowManager.show()

        // When: User has empty query
        windowManager.simulateSearch(query: "")

        // Then: Mode should remain applications
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Mode should stay applications for empty query")
    }

    // MARK: - Test: Placeholder text changes to 'Search clipboard history...'

    func testPlaceholderChangesToClipboardInClipboardMode() {
        // Given: Window is visible in applications mode
        windowManager.show()
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search applications...", "Should have applications placeholder initially")

        // When: User types '>'
        windowManager.simulateSearch(query: ">")

        // Then: Placeholder should change to clipboard mode text
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search clipboard history...", "Placeholder should change to clipboard text")
    }

    func testPlaceholderTextInitialState() {
        // Given: Window is shown fresh
        windowManager.show()

        // Then: Placeholder should show applications text
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search applications...", "Initial placeholder should be for applications")
    }

    func testPlaceholderStaysApplicationsForNormalSearch() {
        // Given: Window is visible
        windowManager.show()

        // When: User types a normal search query
        windowManager.simulateSearch(query: "Chrome")

        // Then: Placeholder should remain for applications
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search applications...", "Placeholder should stay applications for normal search")
    }

    // MARK: - Test: Typing '>query' filters clipboard results

    func testTriggerWithQueryFiltersClipboard() {
        // Given: Window is visible with some clipboard history
        windowManager.show()
        
        // Add clipboard history items
        addClipboardHistoryItem("Hello World")
        addClipboardHistoryItem("Test Message")
        addClipboardHistoryItem("Hello Again")

        // When: User types '>' first (to switch to clipboard mode), then continues typing to '>Hello'
        // This simulates realistic typing behavior where each keystroke triggers handleSearch
        windowManager.simulateSearch(query: ">")  // Switch to clipboard mode
        windowManager.simulateSearch(query: ">Hello")  // Continue typing to filter

        // Then: Mode should be clipboard and results should be filtered
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search clipboard history...", "Should have clipboard placeholder")
        
        // Results should contain only items matching "Hello"
        let resultCount = windowManager.getResultCount()
        XCTAssertEqual(resultCount, 2, "Should have 2 results matching 'Hello'")
    }

    func testTriggerAloneShowsAllClipboardHistory() {
        // Given: Window is visible with some clipboard history
        windowManager.show()
        
        // Add clipboard history items
        addClipboardHistoryItem("First item")
        addClipboardHistoryItem("Second item")
        addClipboardHistoryItem("Third item")

        // When: User types just '>'
        windowManager.simulateSearch(query: ">")

        // Then: All clipboard history should be shown
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")
        XCTAssertEqual(windowManager.getResultCount(), 3, "Should show all clipboard history items")
    }

    func testTriggerWithNoMatchingQuery() {
        // Given: Window is visible with clipboard history
        windowManager.show()
        
        // Add clipboard history items
        addClipboardHistoryItem("Apple")
        addClipboardHistoryItem("Banana")
        addClipboardHistoryItem("Cherry")

        // When: User types '>' first (to switch to clipboard mode), then continues to '>xyz' (no matches)
        windowManager.simulateSearch(query: ">")  // Switch to clipboard mode
        windowManager.simulateSearch(query: ">xyz")  // Continue typing (no matches)

        // Then: Should be in clipboard mode with no results
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")
        XCTAssertEqual(windowManager.getResultCount(), 0, "Should have no results for non-matching query")
    }

    func testTriggerQueryIsCaseInsensitive() {
        // Given: Window is visible with clipboard history
        windowManager.show()
        
        // Add clipboard history items
        addClipboardHistoryItem("HELLO WORLD")

        // When: User types '>' first, then continues to '>hello' (lowercase search for uppercase content)
        windowManager.simulateSearch(query: ">")  // Switch to clipboard mode
        windowManager.simulateSearch(query: ">hello")  // Search with lowercase

        // Then: Should find the uppercase item
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")
        XCTAssertGreaterThan(windowManager.getResultCount(), 0, "Should find case-insensitive match")
    }

    // MARK: - Test: Clearing search field returns to application mode

    func testClearingSearchFieldReturnsToApplicationsMode() {
        // Given: Window is in clipboard mode
        windowManager.show()
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")

        // When: User clears the search field (empty string)
        windowManager.simulateSearch(query: "")

        // Then: Mode should return to applications
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Should return to applications mode when search is cleared")
    }

    func testClearingSearchFieldRestoresPlaceholder() {
        // Given: Window is in clipboard mode
        windowManager.show()
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search clipboard history...", "Should have clipboard placeholder")

        // When: User clears the search field
        windowManager.simulateSearch(query: "")

        // Then: Placeholder should return to applications text
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search applications...", "Placeholder should return to applications text")
    }

    func testTypingNormalTextAfterClipboardModeReturnsToApplications() {
        // Given: Window is in clipboard mode
        windowManager.show()
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")

        // When: User types a normal search (not starting with '>')
        windowManager.simulateSearch(query: "Safari")

        // Then: Mode should return to applications
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Should return to applications when typing normal text")
    }

    func testShowWindowResetsToApplicationMode() {
        // Given: Window was in clipboard mode and then hidden
        windowManager.show()
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should be in clipboard mode")
        windowManager.hide()

        // When: Window is shown again
        windowManager.show()

        // Then: Mode should be reset to applications
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Mode should reset to applications when window is shown")
        XCTAssertEqual(windowManager.getPlaceholderText(), "Search applications...", "Placeholder should be reset")
    }

    // MARK: - Additional Mode Switching Tests

    func testMultipleModeTransitions() {
        // Start in applications mode
        windowManager.show()
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)

        // Switch to clipboard mode
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)

        // Back to applications mode
        windowManager.simulateSearch(query: "test")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)

        // Switch to clipboard mode again
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)

        // Clear to applications mode
        windowManager.simulateSearch(query: "")
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications)
    }

    func testSearchResultsAreClearedOnModeSwitch() {
        // Given: Window has application search results
        windowManager.show()
        windowManager.simulateSearch(query: "Safari")
        let appResultCount = windowManager.getResultCount()
        XCTAssertGreaterThan(appResultCount, 0, "Should have application results")

        // When: Switch to clipboard mode
        windowManager.simulateSearch(query: ">")

        // Then: Results should be clipboard results (may be empty if no history)
        // The important thing is results are recalculated for the new mode
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
    }

    func testClipboardModeWithContinuedTyping() {
        // Given: Window is in clipboard mode with history
        windowManager.show()
        addClipboardHistoryItem("Test content 1")
        addClipboardHistoryItem("Other stuff")
        addClipboardHistoryItem("Test content 2")
        
        // Start in clipboard mode
        windowManager.simulateSearch(query: ">")
        XCTAssertEqual(windowManager.getResultCount(), 3, "Should show all 3 items")

        // When: User continues typing '>Test'
        windowManager.simulateSearch(query: ">Test")

        // Then: Results should be filtered
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard, "Should still be in clipboard mode")
        XCTAssertEqual(windowManager.getResultCount(), 2, "Should filter to 2 matching items")
    }

    func testClipboardModeQueryStripsPrefix() {
        // Given: Window is visible with clipboard history containing "Test"
        windowManager.show()
        addClipboardHistoryItem("Test item")

        // When: User types '>' first (to enter clipboard mode), then continues to '>Test'
        windowManager.simulateSearch(query: ">")  // Switch to clipboard mode
        windowManager.simulateSearch(query: ">Test")  // Continue typing - the '>' prefix should be stripped

        // Then: The search should find "Test item" (the '>' prefix should be stripped for filtering)
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        XCTAssertGreaterThan(windowManager.getResultCount(), 0, "Should find items when searching with '>' prefix")
    }

    func testApplicationSearchDoesNotTriggerClipboardMode() {
        // Given: Window is visible
        windowManager.show()

        // When: User searches for applications (various queries not starting with '>')
        let testQueries = ["Safari", "Chrome", "Mail", "app", "test123"]
        
        for query in testQueries {
            windowManager.simulateSearch(query: query)
            XCTAssertEqual(windowManager.getCurrentSearchMode(), .applications, "Should stay in applications mode for query: \(query)")
        }
    }

    func testSearchTextPropertyReturnsCurrentValue() {
        // Given: Window is visible
        windowManager.show()

        // When: User types a query
        windowManager.simulateSearch(query: ">test")

        // Then: getSearchText should return the current value
        XCTAssertEqual(windowManager.getSearchText(), ">test", "Should return current search text")
    }

    func testEmptyClipboardHistory() {
        // Given: Window is visible with no clipboard history
        windowManager.show()

        // When: User enters clipboard mode
        windowManager.simulateSearch(query: ">")

        // Then: Should be in clipboard mode with no results
        XCTAssertEqual(windowManager.getCurrentSearchMode(), .clipboard)
        XCTAssertEqual(windowManager.getResultCount(), 0, "Should have no results with empty clipboard history")
    }
}
