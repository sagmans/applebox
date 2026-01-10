import XCTest
import SnapshotTesting
import AppKit
@testable import AppleBox

/// Snapshot tests for UI components to catch visual regressions.
/// These tests create images of views in various states and compare them to reference images.
final class SnapshotTests: XCTestCase {
    
    private var mockFileSystem: MockFileSystem!
    private var mockPasteboard: MockPasteboard!
    private var mockWorkspace: MockWorkspace!
    private var mockEventSource: MockEventSource!
    private var windowManager: WindowManager!
    private var searchService: SearchService!
    private var applicationIndexer: ApplicationIndexer!
    
    override func setUp() {
        super.setUp()
        
        // Create mock dependencies
        mockFileSystem = MockFileSystem()
        mockPasteboard = MockPasteboard()
        mockWorkspace = MockWorkspace()
        mockEventSource = MockEventSource()
        
        // Configure mock file system for Application Support directory
        let appSupportURL = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        mockFileSystem.mockURLs = [appSupportURL]
        
        // Create WindowManager with mocks
        windowManager = WindowManager(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )
        
        // Create ApplicationIndexer and SearchService
        applicationIndexer = ApplicationIndexer(fileSystem: mockFileSystem)
        searchService = SearchService(indexer: applicationIndexer)
        windowManager.setSearchService(searchService)
        
        // Set up clipboard manager
        let clipboardManager = ClipboardManager(
            pasteboard: mockPasteboard,
            fileSystem: mockFileSystem
        )
        windowManager.setClipboardManager(clipboardManager)
    }
    
    override func tearDown() {
        windowManager = nil
        searchService = nil
        applicationIndexer = nil
        mockFileSystem = nil
        mockPasteboard = nil
        mockWorkspace = nil
        mockEventSource = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    /// Creates sample ApplicationInfo for testing
    private func createSampleApps() -> [ApplicationInfo] {
        return [
            ApplicationInfo(name: "Safari", bundlePath: "/Applications/Safari.app"),
            ApplicationInfo(name: "Mail", bundlePath: "/Applications/Mail.app"),
            ApplicationInfo(name: "Notes", bundlePath: "/Applications/Notes.app"),
            ApplicationInfo(name: "Calendar", bundlePath: "/Applications/Calendar.app"),
            ApplicationInfo(name: "Reminders", bundlePath: "/Applications/Reminders.app"),
        ]
    }
    
    /// Creates sample SearchResults for testing
    private func createSampleSearchResults() -> [SearchResult] {
        let apps = createSampleApps()
        return apps.enumerated().map { index, app in
            SearchResult(application: app, score: 100 - index * 10)
        }
    }
    
    /// Creates sample ClipboardItems for testing
    private func createSampleClipboardItems() -> [ClipboardItem] {
        return [
            ClipboardItem(content: "Hello, World!"),
            ClipboardItem(content: "https://example.com/path/to/resource"),
            ClipboardItem(content: "Some longer text that might appear in clipboard history that the user copied recently."),
            ClipboardItem(content: "{ \"key\": \"value\", \"number\": 42 }"),
            ClipboardItem(content: "user@example.com"),
        ]
    }
    
    // MARK: - Snapshot Tests for Empty State
    
    func testSnapshotEmptySearchState() {
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot of empty state
        assertSnapshot(of: contentView, as: .image)
    }
    
    // MARK: - Snapshot Tests for Populated Search Results
    
    func testSnapshotPopulatedSearchResults() {
        // Set up search results
        let results = createSampleSearchResults()
        windowManager.setSearchResultsForTesting(results)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot of populated state
        assertSnapshot(of: contentView, as: .image)
    }
    
    // MARK: - Snapshot Tests for Clipboard Mode Results
    
    func testSnapshotClipboardModeResults() {
        // Set up clipboard results
        let items = createSampleClipboardItems()
        windowManager.setClipboardResultsForTesting(items)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot of clipboard mode
        assertSnapshot(of: contentView, as: .image)
    }
    
    // MARK: - Snapshot Tests for Selected Row Highlighting
    
    func testSnapshotSelectedRowHighlighting() {
        // Set up search results
        let results = createSampleSearchResults()
        windowManager.setSearchResultsForTesting(results)
        
        // Select a specific row (middle item)
        windowManager.selectRowForTesting(2)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot with selection
        assertSnapshot(of: contentView, as: .image)
    }
    
    // MARK: - Additional Snapshot Tests
    
    func testSnapshotClipboardModeWithSelection() {
        // Set up clipboard results
        let items = createSampleClipboardItems()
        windowManager.setClipboardResultsForTesting(items)
        
        // Select a specific row
        windowManager.selectRowForTesting(1)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot with clipboard selection
        assertSnapshot(of: contentView, as: .image)
    }
    
    func testSnapshotManySearchResults() {
        // Create many results to test scrolling appearance
        var apps: [ApplicationInfo] = []
        for i in 1...15 {
            apps.append(ApplicationInfo(name: "Application \(i)", bundlePath: "/Applications/App\(i).app"))
        }
        let results = apps.enumerated().map { index, app in
            SearchResult(application: app, score: 200 - index * 10)
        }
        windowManager.setSearchResultsForTesting(results)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot with many results
        assertSnapshot(of: contentView, as: .image)
    }
    
    func testSnapshotFirstRowSelected() {
        // Set up search results
        let results = createSampleSearchResults()
        windowManager.setSearchResultsForTesting(results)
        
        // First row is selected by default, but explicitly select it
        windowManager.selectRowForTesting(0)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot with first row selected
        assertSnapshot(of: contentView, as: .image)
    }
    
    func testSnapshotLastRowSelected() {
        // Set up search results
        let results = createSampleSearchResults()
        windowManager.setSearchResultsForTesting(results)
        
        // Select the last row
        windowManager.selectRowForTesting(results.count - 1)
        
        // Get the content view
        guard let contentView = windowManager.getContentView() else {
            XCTFail("Content view should exist")
            return
        }
        
        // Ensure the view has proper layout
        contentView.layoutSubtreeIfNeeded()
        
        // Take snapshot with last row selected
        assertSnapshot(of: contentView, as: .image)
    }
}
