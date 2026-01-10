import XCTest
import AppKit
@testable import AppleBox

/// Accessibility tests verifying the UI is accessible
final class AccessibilityTests: XCTestCase {

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
        let notesApp = URL(fileURLWithPath: "/System/Applications/Notes.app")

        mockFileSystem.addDirectory(at: systemAppsURL, contents: [safariApp, mailApp, notesApp])
        mockFileSystem.addFile(at: safariApp.path, isDirectory: true)
        mockFileSystem.addFile(at: mailApp.path, isDirectory: true)
        mockFileSystem.addFile(at: notesApp.path, isDirectory: true)

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

    // MARK: - Search Field Accessibility Tests

    func testSearchFieldHasAccessibilityIdentifier() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the search field
        let searchField = windowManager.getSearchField()

        // Then: Search field should have accessibility identifier
        XCTAssertNotNil(searchField, "Search field should exist")
        XCTAssertEqual(searchField?.accessibilityIdentifier(), "AppleBoxSearchField", "Search field should have correct accessibility identifier")
    }

    func testSearchFieldHasAccessibilityLabel() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the search field
        let searchField = windowManager.getSearchField()

        // Then: Search field should have accessibility label
        XCTAssertNotNil(searchField, "Search field should exist")
        XCTAssertEqual(searchField?.accessibilityLabel(), "Search Field", "Search field should have correct accessibility label")
    }

    func testSearchFieldHasAccessibilityHelp() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the search field
        let searchField = windowManager.getSearchField()

        // Then: Search field should have accessibility help text
        XCTAssertNotNil(searchField, "Search field should exist")
        let helpText = searchField?.accessibilityHelp()
        XCTAssertNotNil(helpText, "Search field should have accessibility help")
        XCTAssertTrue(helpText?.contains("search") ?? false, "Help text should mention search functionality")
        XCTAssertTrue(helpText?.contains(">") ?? false || helpText?.contains("clipboard") ?? false, "Help text should mention clipboard trigger")
    }

    func testSearchFieldHasAccessibleChildren() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the search field
        let searchField = windowManager.getSearchField()

        // Then: Search field should have accessible children
        // NSSearchField is a composite control with child accessibility elements
        // (search button, text field, clear button), so it itself may not be an element,
        // but it should have accessibility children
        XCTAssertNotNil(searchField, "Search field should exist")
        
        // Verify the search field participates in accessibility hierarchy
        // Either it is an element, or it contains accessible children
        let accessibilityChildren = searchField?.accessibilityChildren()
        let isElementOrHasChildren = (searchField?.isAccessibilityElement() ?? false) || 
                                      (accessibilityChildren?.isEmpty == false)
        XCTAssertTrue(isElementOrHasChildren, "Search field should be accessible (either as element or via children)")
    }

    // MARK: - Table View Accessibility Tests

    func testTableViewHasAccessibilityIdentifier() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the table view
        let tableView = windowManager.getTableView()

        // Then: Table view should have accessibility identifier
        XCTAssertNotNil(tableView, "Table view should exist")
        XCTAssertEqual(tableView?.accessibilityIdentifier(), "AppleBoxResultsTable", "Table view should have correct accessibility identifier")
    }

    func testTableViewHasAccessibilityLabel() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the table view
        let tableView = windowManager.getTableView()

        // Then: Table view should have accessibility label
        XCTAssertNotNil(tableView, "Table view should exist")
        XCTAssertEqual(tableView?.accessibilityLabel(), "Search Results", "Table view should have correct accessibility label")
    }

    func testTableViewHasAccessibilityHelp() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the table view
        let tableView = windowManager.getTableView()

        // Then: Table view should have accessibility help
        XCTAssertNotNil(tableView, "Table view should exist")
        let helpText = tableView?.accessibilityHelp()
        XCTAssertNotNil(helpText, "Table view should have accessibility help")
        XCTAssertTrue(helpText?.contains("arrow") ?? false, "Help text should mention arrow key navigation")
        XCTAssertTrue(helpText?.contains("Enter") ?? false, "Help text should mention Enter key to select")
    }

    // MARK: - Table Row Accessibility Tests

    func testApplicationRowsHaveAccessibilityIdentifiers() {
        // Given: WindowManager has search results
        windowManager.show()
        windowManager.simulateSearch(query: "Safari")

        // When: We get a cell view
        let cellView = windowManager.getCellViewForTesting(at: 0)

        // Then: Cell should have accessibility identifier
        XCTAssertNotNil(cellView, "Cell view should exist for first row")
        let identifier = cellView?.accessibilityIdentifier()
        XCTAssertNotNil(identifier, "Cell should have accessibility identifier")
        XCTAssertTrue(identifier?.hasPrefix("ApplicationRow_") ?? false, "Application row should have ApplicationRow_ prefix")
    }

    func testApplicationRowsHaveAccessibilityLabels() {
        // Given: WindowManager has search results
        windowManager.show()
        windowManager.simulateSearch(query: "Safari")

        // When: We get a cell view
        let cellView = windowManager.getCellViewForTesting(at: 0)

        // Then: Cell should have accessibility label with app name
        XCTAssertNotNil(cellView, "Cell view should exist for first row")
        let label = cellView?.accessibilityLabel()
        XCTAssertNotNil(label, "Cell should have accessibility label")
        XCTAssertTrue(label?.contains("Application:") ?? false, "Label should indicate it's an application")
        XCTAssertTrue(label?.contains("Safari") ?? false, "Label should contain app name")
    }

    func testApplicationRowsHaveAccessibilityHelp() {
        // Given: WindowManager has search results
        windowManager.show()
        windowManager.simulateSearch(query: "Safari")

        // When: We get a cell view
        let cellView = windowManager.getCellViewForTesting(at: 0)

        // Then: Cell should have accessibility help
        XCTAssertNotNil(cellView, "Cell view should exist for first row")
        let helpText = cellView?.accessibilityHelp()
        XCTAssertNotNil(helpText, "Cell should have accessibility help")
        XCTAssertTrue(helpText?.contains("launch") ?? false, "Help should mention launching application")
    }

    func testClipboardRowsHaveAccessibilityIdentifiers() {
        // Given: WindowManager has clipboard results
        windowManager.show()

        // Add clipboard history
        mockPasteboard.simulateExternalChange(content: "Test clipboard item")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))

        // Switch to clipboard mode
        windowManager.simulateSearch(query: ">")

        // When: We get a cell view
        let cellView = windowManager.getCellViewForTesting(at: 0)

        // Then: Cell should have accessibility identifier for clipboard
        XCTAssertNotNil(cellView, "Cell view should exist for clipboard item")
        let identifier = cellView?.accessibilityIdentifier()
        XCTAssertNotNil(identifier, "Cell should have accessibility identifier")
        XCTAssertTrue(identifier?.hasPrefix("ClipboardRow_") ?? false, "Clipboard row should have ClipboardRow_ prefix")
    }

    func testClipboardRowsHaveAccessibilityLabels() {
        // Given: WindowManager has clipboard results
        windowManager.show()

        // Add clipboard history
        mockPasteboard.simulateExternalChange(content: "Test clipboard content")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))

        // Switch to clipboard mode
        windowManager.simulateSearch(query: ">")

        // When: We get a cell view
        let cellView = windowManager.getCellViewForTesting(at: 0)

        // Then: Cell should have accessibility label with content
        XCTAssertNotNil(cellView, "Cell view should exist for clipboard item")
        let label = cellView?.accessibilityLabel()
        XCTAssertNotNil(label, "Cell should have accessibility label")
        XCTAssertTrue(label?.contains("Clipboard item:") ?? false, "Label should indicate it's a clipboard item")
    }

    func testClipboardRowsHaveAccessibilityHelp() {
        // Given: WindowManager has clipboard results
        windowManager.show()

        // Add clipboard history
        mockPasteboard.simulateExternalChange(content: "Clipboard test")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))

        // Switch to clipboard mode
        windowManager.simulateSearch(query: ">")

        // When: We get a cell view
        let cellView = windowManager.getCellViewForTesting(at: 0)

        // Then: Cell should have accessibility help
        XCTAssertNotNil(cellView, "Cell view should exist for clipboard item")
        let helpText = cellView?.accessibilityHelp()
        XCTAssertNotNil(helpText, "Cell should have accessibility help")
        XCTAssertTrue(helpText?.contains("copy") ?? false, "Help should mention copying to clipboard")
    }

    // MARK: - Keyboard Navigation Tests

    func testKeyboardNavigationWorksWithoutMouse() {
        // Given: Window is visible with search results
        windowManager.show()
        windowManager.simulateSearch(query: "a") // Search for apps containing 'a'

        // Verify we have results
        XCTAssertGreaterThan(windowManager.getResultCount(), 0, "Should have search results")

        // Then: Initial selection should be first row (row 0)
        XCTAssertEqual(windowManager.getSelectedRowIndex(), 0, "First row should be selected initially")
    }

    func testArrowDownNavigatesWithoutMouse() {
        // Given: Window is visible with search results
        windowManager.show()
        windowManager.simulateSearch(query: "a") // Should match Safari, Mail, etc.

        // Verify we have at least 2 results
        XCTAssertGreaterThanOrEqual(windowManager.getResultCount(), 2, "Should have at least 2 search results")

        // Initial selection should be row 0
        XCTAssertEqual(windowManager.getSelectedRowIndex(), 0, "Initial selection should be row 0")

        // When: User navigates down using arrow key (simulated via selectRowForTesting)
        windowManager.selectRowForTesting(1)

        // Then: Selection should move to row 1
        XCTAssertEqual(windowManager.getSelectedRowIndex(), 1, "Selection should move to row 1")
    }

    func testArrowUpNavigatesWithoutMouse() {
        // Given: Window is visible with search results and selection at row 1
        windowManager.show()
        windowManager.simulateSearch(query: "a")

        // Verify we have at least 2 results
        XCTAssertGreaterThanOrEqual(windowManager.getResultCount(), 2, "Should have at least 2 search results")

        // Move selection to row 1
        windowManager.selectRowForTesting(1)
        XCTAssertEqual(windowManager.getSelectedRowIndex(), 1, "Selection should be at row 1")

        // When: User navigates up using arrow key (simulated)
        windowManager.selectRowForTesting(0)

        // Then: Selection should move to row 0
        XCTAssertEqual(windowManager.getSelectedRowIndex(), 0, "Selection should move back to row 0")
    }

    func testFullKeyboardNavigationCycle() {
        // Given: Window is visible with multiple search results
        windowManager.show()
        windowManager.simulateSearch(query: "a")

        let resultCount = windowManager.getResultCount()
        XCTAssertGreaterThanOrEqual(resultCount, 2, "Should have at least 2 results")

        // When: Navigate through all rows
        for row in 0..<resultCount {
            windowManager.selectRowForTesting(row)
            XCTAssertEqual(windowManager.getSelectedRowIndex(), row, "Selection should be at row \(row)")
        }

        // Navigate back up
        for row in stride(from: resultCount - 1, through: 0, by: -1) {
            windowManager.selectRowForTesting(row)
            XCTAssertEqual(windowManager.getSelectedRowIndex(), row, "Selection should be at row \(row)")
        }
    }

    // MARK: - VoiceOver Compatibility Tests

    func testSearchFieldLabelIsReadable() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the search field's accessibility label
        let searchField = windowManager.getSearchField()
        let label = searchField?.accessibilityLabel()

        // Then: Label should be human-readable (not empty, not a UUID, etc.)
        XCTAssertNotNil(label, "Label should not be nil")
        XCTAssertFalse(label?.isEmpty ?? true, "Label should not be empty")
        XCTAssertFalse(label?.hasPrefix("_") ?? false, "Label should not be an internal identifier")
        XCTAssertFalse(label?.contains("-") ?? false && (label?.count ?? 0) > 30, "Label should not be a UUID")
    }

    func testTableViewLabelIsReadable() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the table view's accessibility label
        let tableView = windowManager.getTableView()
        let label = tableView?.accessibilityLabel()

        // Then: Label should be human-readable
        XCTAssertNotNil(label, "Label should not be nil")
        XCTAssertFalse(label?.isEmpty ?? true, "Label should not be empty")
        XCTAssertTrue(label?.contains("Results") ?? false || label?.contains("Search") ?? false, "Label should describe the table's purpose")
    }

    func testApplicationRowLabelIsReadableWithContent() {
        // Given: WindowManager has search results
        windowManager.show()
        windowManager.simulateSearch(query: "Safari")

        // When: We get a cell view's accessibility label
        let cellView = windowManager.getCellViewForTesting(at: 0)
        let label = cellView?.accessibilityLabel()

        // Then: Label should be descriptive and include the app name
        XCTAssertNotNil(label, "Label should not be nil")
        XCTAssertTrue(label?.count ?? 0 > 5, "Label should have meaningful length")
        // Should contain either the app name or the word "Application"
        XCTAssertTrue(
            (label?.contains("Safari") ?? false) || (label?.contains("Application") ?? false),
            "Label should describe the application"
        )
    }

    func testClipboardRowLabelIsReadableWithContent() {
        // Given: WindowManager has clipboard results
        windowManager.show()

        // Add clipboard history with meaningful content
        mockPasteboard.simulateExternalChange(content: "Important meeting notes")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))

        // Switch to clipboard mode
        windowManager.simulateSearch(query: ">")

        // When: We get a cell view's accessibility label
        let cellView = windowManager.getCellViewForTesting(at: 0)
        let label = cellView?.accessibilityLabel()

        // Then: Label should be descriptive and include content preview
        XCTAssertNotNil(label, "Label should not be nil")
        XCTAssertTrue(label?.count ?? 0 > 5, "Label should have meaningful length")
        XCTAssertTrue(
            (label?.contains("Clipboard") ?? false) || (label?.contains("Important") ?? false),
            "Label should describe the clipboard item"
        )
    }

    // MARK: - Window Accessibility Tests

    func testWindowHasAccessibilityIdentifier() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the window
        let window = windowManager.getWindow()

        // Then: Window should have accessibility identifier
        XCTAssertNotNil(window, "Window should exist")
        XCTAssertEqual(window?.accessibilityIdentifier(), "AppleBoxWindow", "Window should have correct accessibility identifier")
    }

    func testWindowHasAccessibilityLabel() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the window
        let window = windowManager.getWindow()

        // Then: Window should have accessibility label
        XCTAssertNotNil(window, "Window should exist")
        let label = window?.accessibilityLabel()
        XCTAssertNotNil(label, "Window should have accessibility label")
        XCTAssertTrue(label?.contains("AppleBox") ?? false, "Window label should mention AppleBox")
    }

    func testWindowHasAccessibilityHelp() {
        // Given: WindowManager is set up
        windowManager.show()

        // When: We get the window
        let window = windowManager.getWindow()

        // Then: Window should have accessibility help
        XCTAssertNotNil(window, "Window should exist")
        let helpText = window?.accessibilityHelp()
        XCTAssertNotNil(helpText, "Window should have accessibility help")
        XCTAssertTrue(helpText?.contains("launcher") ?? false || helpText?.contains("applications") ?? false, "Help should describe purpose")
    }

    // MARK: - Accessibility Element Count Tests

    func testAccessibilityElementsAreDiscoverable() {
        // Given: WindowManager is set up with search results
        windowManager.show()
        windowManager.simulateSearch(query: "a")

        // Then: Key accessibility elements should be discoverable
        XCTAssertNotNil(windowManager.getWindow(), "Window should be discoverable")
        XCTAssertNotNil(windowManager.getSearchField(), "Search field should be discoverable")
        XCTAssertNotNil(windowManager.getTableView(), "Table view should be discoverable")
        
        // If we have results, cells should be discoverable too
        if windowManager.getResultCount() > 0 {
            XCTAssertNotNil(windowManager.getCellViewForTesting(at: 0), "First cell should be discoverable")
        }
    }

    // MARK: - Search Mode Accessibility Tests

    func testSearchFieldPlaceholderChangesForClipboardMode() {
        // Given: WindowManager is in application mode
        windowManager.show()

        // When: Switch to clipboard mode
        windowManager.simulateSearch(query: ">")

        // Then: Placeholder should reflect clipboard mode
        let placeholder = windowManager.getPlaceholderText()
        XCTAssertTrue(placeholder?.contains("clipboard") ?? false, "Placeholder should mention clipboard in clipboard mode")
    }

    func testSearchFieldPlaceholderChangesBackToApplicationMode() {
        // Given: WindowManager was in clipboard mode
        windowManager.show()
        windowManager.simulateSearch(query: ">")

        // When: Clear search to return to application mode
        windowManager.simulateSearch(query: "")

        // Then: Placeholder should reflect application mode
        let placeholder = windowManager.getPlaceholderText()
        XCTAssertTrue(placeholder?.contains("applications") ?? false, "Placeholder should mention applications in application mode")
    }
}
