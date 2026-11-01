@testable import AppleBox
import XCTest

/// Integration tests verifying clipboard capture and retrieval works end-to-end.
/// These tests verify the full flow from pasteboard changes through ClipboardManager to history retrieval.
final class ClipboardFlowIntegrationTests: XCTestCase {
    var mockPasteboard: MockPasteboard!
    var mockFileSystem: MockFileSystem!
    var storageURL: URL!

    override func setUp() {
        super.setUp()
        mockPasteboard = MockPasteboard()
        mockFileSystem = MockFileSystem()

        // Configure mock file system with Application Support directory
        let appSupportURL = URL(fileURLWithPath: "/Users/testuser/Library/Application Support")
        mockFileSystem.mockURLs = [appSupportURL]

        // Calculate the expected storage path
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        storageURL = appDirectory.appendingPathComponent("clipboard_history.json")
    }

    override func tearDown() {
        mockPasteboard = nil
        mockFileSystem = nil
        storageURL = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Creates a ClipboardManager with the mock dependencies
    private func createManager(pasteboard: MockPasteboard? = nil, fileSystem: MockFileSystem? = nil) -> ClipboardManager {
        ClipboardManager(
            pasteboard: pasteboard ?? mockPasteboard,
            fileSystem: fileSystem ?? mockFileSystem
        )
    }

    /// Simulates a clipboard change and polls the pasteboard once.
    /// Calling `checkForChanges()` directly avoids racing the 0.5 s monitor
    /// timer, which can fire late on a loaded runner.
    private func simulateClipboardChange(
        content: String,
        in manager: ClipboardManager,
        pasteboard: MockPasteboard? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pb = pasteboard ?? mockPasteboard!
        pb.simulateExternalChange(content: content)
        manager.checkForChanges()
        XCTAssertEqual(manager.getHistory().first?.content, content, file: file, line: line)
        // Persistence happens on a background queue; flush to keep tests deterministic.
        manager.flushPendingPersistence()
    }

    /// Encodes clipboard items to JSON data (matching ClipboardManager's format)
    private func encodeHistory(_ items: [ClipboardItem]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(items)
    }

    // MARK: - Test: End-to-End Flow (Mock Pasteboard Change -> ClipboardManager -> History Retrieval)

    func testEndToEndClipboardFlow() {
        // Given - A fresh ClipboardManager with mock dependencies
        let manager = createManager()
        XCTAssertEqual(manager.getHistory().count, 0, "History should start empty")

        // When - External application copies text to clipboard
        simulateClipboardChange(content: "First copied text", in: manager)

        // Then - ClipboardManager captures and makes it available via history
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 1, "Should capture clipboard change")
        XCTAssertEqual(history.first?.content, "First copied text")
    }

    func testEndToEndFlowWithMultipleClipboardChanges() {
        // Given - A fresh ClipboardManager
        let manager = createManager()

        // When - Multiple clipboard changes occur
        simulateClipboardChange(content: "Text from app A", in: manager)
        simulateClipboardChange(content: "Text from app B", in: manager)
        simulateClipboardChange(content: "Text from app C", in: manager)

        // Then - All changes captured in correct order (most recent first)
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].content, "Text from app C")
        XCTAssertEqual(history[1].content, "Text from app B")
        XCTAssertEqual(history[2].content, "Text from app A")
    }

    func testEndToEndFlowIgnoresConsecutiveDuplicates() {
        // Given - A fresh ClipboardManager
        let manager = createManager()

        // When - Same content is copied multiple times in a row
        simulateClipboardChange(content: "Repeated text", in: manager)
        simulateClipboardChange(content: "Repeated text", in: manager)
        simulateClipboardChange(content: "Repeated text", in: manager)

        // Then - Only one entry in history
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 1, "Consecutive duplicates should be ignored")
        XCTAssertEqual(history.first?.content, "Repeated text")
    }

    func testEndToEndFlowWithEmptyClipboard() {
        // Given - A fresh ClipboardManager
        let manager = createManager()

        // When - Clipboard is set to empty content
        mockPasteboard.simulateExternalChange(content: "")
        manager.checkForChanges()

        // Then - Empty content is ignored
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 0, "Empty clipboard content should be ignored")
    }

    func testEndToEndFlowWithNilClipboard() {
        // Given - A fresh ClipboardManager
        let manager = createManager()

        // When - Clipboard has non-text content (nil string)
        mockPasteboard.simulateExternalChange(content: nil)
        manager.checkForChanges()

        // Then - Non-text content is ignored
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 0, "Non-text clipboard content should be ignored")
    }

    // MARK: - Test: Clipboard History Persists Across Manager Instances (via Mock File System)

    func testHistoryPersistsAcrossManagerInstances() {
        // Given - First manager captures clipboard content
        let manager1 = createManager()
        simulateClipboardChange(content: "Persisted item 1", in: manager1)
        simulateClipboardChange(content: "Persisted item 2", in: manager1)

        // When - Create a new manager instance (simulates app restart)
        // Use a fresh pasteboard but SAME file system to verify persistence
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)

        // Then - Second manager loads persisted history
        let history = manager2.getHistory()
        XCTAssertEqual(history.count, 2, "History should persist across manager instances")
        guard history.count == 2 else { return }
        XCTAssertEqual(history[0].content, "Persisted item 2")
        XCTAssertEqual(history[1].content, "Persisted item 1")
    }

    func testHistoryPersistsWithManyItems() {
        // Given - First manager captures many items
        let manager1 = createManager()
        for i in 1 ... 10 {
            simulateClipboardChange(content: "Item \(i)", in: manager1)
        }

        // When - Create new manager instance
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)

        // Then - All items persist correctly
        let history = manager2.getHistory()
        XCTAssertEqual(history.count, 10)
        XCTAssertEqual(history.first?.content, "Item 10", "Most recent should be first")
        XCTAssertEqual(history.last?.content, "Item 1", "Oldest should be last")
    }

    func testNewItemsAppendToPersistedHistory() {
        // Given - First manager with some history
        let manager1 = createManager()
        simulateClipboardChange(content: "Original item", in: manager1)

        // Wait for async persistence to complete before creating second manager
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // When - Second manager adds more items
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)
        simulateClipboardChange(content: "New item", in: manager2, pasteboard: freshPasteboard)

        // Then - Both old and new items present
        let history = manager2.getHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].content, "New item")
        XCTAssertEqual(history[1].content, "Original item")
    }

    func testPersistenceWithNoExistingFile() {
        // Given - No history file exists (fresh install scenario)
        XCTAssertNil(mockFileSystem.fileContents[storageURL.path])

        // When - Manager starts and captures content
        let manager = createManager()
        simulateClipboardChange(content: "First ever item", in: manager)

        // Then - Content is saved to file system
        XCTAssertNotNil(mockFileSystem.fileContents[storageURL.path], "History should be persisted")

        // Verify by creating new manager
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)
        XCTAssertEqual(manager2.getHistory().count, 1)
        XCTAssertEqual(manager2.getHistory().first?.content, "First ever item")
    }

    func testPersistenceCreatesDirectoryIfNeeded() {
        // Given - AppleBox directory doesn't exist
        let appDirectory = URL(fileURLWithPath: "/Users/testuser/Library/Application Support/AppleBox")
        XCTAssertFalse(mockFileSystem.existingFiles[appDirectory.path] ?? false)

        // When - Manager is created
        _ = createManager()

        // Then - Directory is created
        XCTAssertTrue(mockFileSystem.createDirectoryCalls.count > 0, "Should create directory")
        let createCall = mockFileSystem.createDirectoryCalls.first
        XCTAssertEqual(createCall?.url.path, appDirectory.path)
        XCTAssertTrue(createCall?.createIntermediates == true)
    }

    func testPersistenceHandlesCorruptedFile() throws {
        // Given - Corrupted history file exists
        let corruptedData = try XCTUnwrap("{{invalid json}}".data(using: .utf8))
        mockFileSystem.addFile(at: storageURL.path, contents: corruptedData)

        // When - Manager is created
        let manager = createManager()

        // Then - Starts with empty history (graceful degradation)
        XCTAssertEqual(manager.getHistory().count, 0)

        // And can still capture new content
        simulateClipboardChange(content: "Recovery item", in: manager)
        XCTAssertEqual(manager.getHistory().count, 1)
        XCTAssertEqual(manager.getHistory().first?.content, "Recovery item")
    }

    // MARK: - Test: Search Filters History Correctly

    func testSearchFiltersHistoryCorrectly() {
        // Given - Manager with various clipboard content
        let manager = createManager()
        simulateClipboardChange(content: "Hello World", in: manager)
        simulateClipboardChange(content: "Goodbye World", in: manager)
        simulateClipboardChange(content: "Hello Universe", in: manager)
        simulateClipboardChange(content: "Random text", in: manager)

        // When - Search for "Hello"
        let results = manager.searchHistory(query: "Hello")

        // Then - Only matching items returned
        XCTAssertEqual(results.count, 2)
        let contents = results.map(\.content)
        XCTAssertTrue(contents.contains("Hello World"))
        XCTAssertTrue(contents.contains("Hello Universe"))
    }

    func testSearchIsCaseInsensitive() {
        // Given - Manager with mixed case content
        let manager = createManager()
        simulateClipboardChange(content: "UPPERCASE TEXT", in: manager)
        simulateClipboardChange(content: "lowercase text", in: manager)
        simulateClipboardChange(content: "MixedCase Text", in: manager)

        // When - Search with different cases
        let resultsLower = manager.searchHistory(query: "text")
        let resultsUpper = manager.searchHistory(query: "TEXT")
        let resultsMixed = manager.searchHistory(query: "TeXt")

        // Then - All searches find the same items
        XCTAssertEqual(resultsLower.count, 3)
        XCTAssertEqual(resultsUpper.count, 3)
        XCTAssertEqual(resultsMixed.count, 3)
    }

    func testSearchWithEmptyQueryReturnsAllHistory() {
        // Given - Manager with clipboard history
        let manager = createManager()
        simulateClipboardChange(content: "Item A", in: manager)
        simulateClipboardChange(content: "Item B", in: manager)
        simulateClipboardChange(content: "Item C", in: manager)

        // When - Search with empty query
        let results = manager.searchHistory(query: "")

        // Then - All items returned
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].content, "Item C")
        XCTAssertEqual(results[1].content, "Item B")
        XCTAssertEqual(results[2].content, "Item A")
    }

    func testSearchWithNoMatchReturnsEmpty() {
        // Given - Manager with clipboard history
        let manager = createManager()
        simulateClipboardChange(content: "Apple", in: manager)
        simulateClipboardChange(content: "Banana", in: manager)

        // When - Search for non-existent term
        let results = manager.searchHistory(query: "xyz123")

        // Then - Empty results
        XCTAssertEqual(results.count, 0)
    }

    func testSearchWithPartialMatchesSubstring() {
        // Given - Manager with clipboard history
        let manager = createManager()
        simulateClipboardChange(content: "Application", in: manager)
        simulateClipboardChange(content: "Documentation", in: manager)
        simulateClipboardChange(content: "Nothing here", in: manager)

        // When - Search for substring "tion"
        let results = manager.searchHistory(query: "tion")

        // Then - Items containing substring are returned
        XCTAssertEqual(results.count, 2)
        let contents = results.map(\.content)
        XCTAssertTrue(contents.contains("Application"))
        XCTAssertTrue(contents.contains("Documentation"))
    }

    func testSearchAfterPersistence() {
        // Given - First manager with history that persists
        let manager1 = createManager()
        simulateClipboardChange(content: "Searchable content", in: manager1)
        simulateClipboardChange(content: "Other stuff", in: manager1)

        // When - New manager loads persisted history and searches
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)
        let results = manager2.searchHistory(query: "Searchable")

        // Then - Search works on persisted history
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.content, "Searchable content")
    }

    // MARK: - Complex Integration Scenarios

    func testFullLifecycleIntegration() {
        // Simulates complete user workflow:
        // 1. Start app (create manager)
        // 2. Copy various items
        // 3. Search history
        // 4. "Restart" app
        // 5. Verify history persisted
        // 6. Continue using

        // Step 1: Initial manager
        let manager1 = createManager()

        // Step 2: Copy items
        simulateClipboardChange(content: "Meeting notes from today", in: manager1)
        simulateClipboardChange(content: "https://example.com", in: manager1)
        simulateClipboardChange(content: "Password123!", in: manager1)
        simulateClipboardChange(content: "Code snippet: let x = 5", in: manager1)

        XCTAssertEqual(manager1.getHistory().count, 4)

        // Step 3: Search
        let urlResults = manager1.searchHistory(query: "http")
        XCTAssertEqual(urlResults.count, 1)
        XCTAssertEqual(urlResults.first?.content, "https://example.com")

        // Step 4: "Restart" app
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)

        // Step 5: Verify persistence
        XCTAssertEqual(manager2.getHistory().count, 4)
        XCTAssertEqual(manager2.getHistory().first?.content, "Code snippet: let x = 5")

        // Step 6: Continue using
        simulateClipboardChange(content: "New item after restart", in: manager2, pasteboard: freshPasteboard)
        XCTAssertEqual(manager2.getHistory().count, 5)
        XCTAssertEqual(manager2.getHistory().first?.content, "New item after restart")
    }

    func testHistoryRespects50ItemLimit() {
        // Given - Manager with many items
        let manager1 = createManager()
        for i in 1 ... 60 {
            simulateClipboardChange(content: "Item \(i)", in: manager1)
        }

        // When - Check limit is enforced
        XCTAssertEqual(manager1.getHistory().count, 50)

        // And verify after persistence
        let freshPasteboard = MockPasteboard()
        let manager2 = ClipboardManager(pasteboard: freshPasteboard, fileSystem: mockFileSystem)
        XCTAssertEqual(manager2.getHistory().count, 50)

        // Most recent 50 items kept (items 11-60)
        XCTAssertEqual(manager2.getHistory().first?.content, "Item 60")
        XCTAssertEqual(manager2.getHistory().last?.content, "Item 11")
    }
}
