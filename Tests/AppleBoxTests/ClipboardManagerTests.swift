import XCTest
@testable import AppleBox

final class ClipboardManagerTests: XCTestCase {
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
    private func createManager() -> ClipboardManager {
        return ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
    }
    
    /// Simulates a clipboard change and waits for the timer to pick it up
    private func simulateClipboardChange(content: String, in manager: ClipboardManager) {
        mockPasteboard.simulateExternalChange(content: content)
        // Manually trigger change detection by running the run loop briefly
        // Since we can't directly trigger the timer, we'll use a different approach
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        manager.flushPendingPersistence()
    }
    
    /// Encodes clipboard items to JSON data (matching ClipboardManager's format)
    private func encodeHistory(_ items: [ClipboardItem]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(items)
    }
    
    /// Creates a ClipboardItem for testing (note: timestamp will be different each time)
    private func createItem(_ content: String) -> ClipboardItem {
        return ClipboardItem(content: content)
    }
    
    // MARK: - Test: New Clipboard Content is Captured When changeCount Changes
    
    func testNewClipboardContentCapturedWhenChangeCountChanges() {
        // Given
        let manager = createManager()
        XCTAssertEqual(manager.getHistory().count, 0, "History should start empty")
        
        // When
        simulateClipboardChange(content: "Test content 1", in: manager)
        
        // Then
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 1, "History should have 1 item after clipboard change")
        XCTAssertEqual(history.first?.content, "Test content 1")
    }
    
    func testMultipleClipboardChangesAreCaptured() {
        // Given
        let manager = createManager()
        
        // When
        simulateClipboardChange(content: "First item", in: manager)
        simulateClipboardChange(content: "Second item", in: manager)
        simulateClipboardChange(content: "Third item", in: manager)
        
        // Then
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 3, "History should have 3 items")
        // Most recent items should be first
        XCTAssertEqual(history[0].content, "Third item")
        XCTAssertEqual(history[1].content, "Second item")
        XCTAssertEqual(history[2].content, "First item")
    }
    
    func testClipboardContentNotCapturedIfChangeCountUnchanged() {
        // Given
        mockPasteboard.setInitialState(content: "Initial content", changeCount: 5)
        let manager = createManager()
        
        // Verify initial state - manager starts with pasteboard's change count
        let initialHistory = manager.getHistory()
        XCTAssertEqual(initialHistory.count, 0, "History should start empty")
        
        // When - run loop without changing changeCount
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        
        // Then - no new content should be captured
        let historyAfterWait = manager.getHistory()
        XCTAssertEqual(historyAfterWait.count, 0, "History should still be empty when changeCount hasn't changed")
    }
    
    // MARK: - Test: Duplicate Consecutive Content is Ignored
    
    func testDuplicateConsecutiveContentIsIgnored() {
        // Given
        let manager = createManager()
        
        // When - copy the same content twice
        simulateClipboardChange(content: "Duplicate content", in: manager)
        simulateClipboardChange(content: "Duplicate content", in: manager)
        
        // Then - should only have one entry
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 1, "Duplicate consecutive content should be ignored")
        XCTAssertEqual(history.first?.content, "Duplicate content")
    }
    
    func testNonConsecutiveDuplicatesAreKept() {
        // Given
        let manager = createManager()
        
        // When - copy content A, then B, then A again
        simulateClipboardChange(content: "Content A", in: manager)
        simulateClipboardChange(content: "Content B", in: manager)
        simulateClipboardChange(content: "Content A", in: manager)
        
        // Then - all three should be kept
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 3, "Non-consecutive duplicates should be kept")
        XCTAssertEqual(history[0].content, "Content A")
        XCTAssertEqual(history[1].content, "Content B")
        XCTAssertEqual(history[2].content, "Content A")
    }
    
    // MARK: - Test: History Limited to maxHistoryCount (50) Items
    
    func testHistoryLimitedToMaxCount() {
        // Given
        let manager = createManager()
        
        // When - add more than 50 items
        for i in 1...55 {
            simulateClipboardChange(content: "Item \(i)", in: manager)
        }
        
        // Then - should only have 50 items
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 50, "History should be limited to 50 items")
        
        // Most recent items should be kept (items 6-55, with 55 being most recent)
        XCTAssertEqual(history.first?.content, "Item 55", "Most recent item should be first")
        XCTAssertEqual(history.last?.content, "Item 6", "Oldest kept item should be item 6")
    }
    
    // MARK: - Test: searchHistory Filters Correctly (Case-Insensitive)
    
    func testSearchHistoryFiltersCaseInsensitive() {
        // Given
        let manager = createManager()
        simulateClipboardChange(content: "Hello World", in: manager)
        simulateClipboardChange(content: "hello there", in: manager)
        simulateClipboardChange(content: "HELLO AGAIN", in: manager)
        simulateClipboardChange(content: "Goodbye world", in: manager)
        
        // When - search with lowercase
        let results = manager.searchHistory(query: "hello")
        
        // Then - should find all items with "hello" regardless of case
        XCTAssertEqual(results.count, 3, "Should find all case variations of 'hello'")
        XCTAssert(results.contains { $0.content == "Hello World" })
        XCTAssert(results.contains { $0.content == "hello there" })
        XCTAssert(results.contains { $0.content == "HELLO AGAIN" })
    }
    
    func testSearchHistoryFiltersCorrectly() {
        // Given
        let manager = createManager()
        simulateClipboardChange(content: "Apple", in: manager)
        simulateClipboardChange(content: "Banana", in: manager)
        simulateClipboardChange(content: "Apricot", in: manager)
        simulateClipboardChange(content: "Orange", in: manager)
        
        // When - search for items containing "an"
        let results = manager.searchHistory(query: "an")
        
        // Then
        XCTAssertEqual(results.count, 2, "Should find items containing 'an'")
        XCTAssert(results.contains { $0.content == "Banana" })
        XCTAssert(results.contains { $0.content == "Orange" })
    }
    
    func testSearchHistoryNoMatchReturnsEmpty() {
        // Given
        let manager = createManager()
        simulateClipboardChange(content: "Hello", in: manager)
        simulateClipboardChange(content: "World", in: manager)
        
        // When - search for non-existent content
        let results = manager.searchHistory(query: "xyz")
        
        // Then
        XCTAssertEqual(results.count, 0, "Should return empty for non-matching query")
    }
    
    // MARK: - Test: Empty Search Returns All History
    
    func testEmptySearchReturnsAllHistory() {
        // Given
        let manager = createManager()
        simulateClipboardChange(content: "First", in: manager)
        simulateClipboardChange(content: "Second", in: manager)
        simulateClipboardChange(content: "Third", in: manager)
        
        // When - search with empty string
        let results = manager.searchHistory(query: "")
        
        // Then
        XCTAssertEqual(results.count, 3, "Empty search should return all items")
        // Verify content matches (comparing by content since we can't use Equatable directly)
        let historyContents = manager.getHistory().map { $0.content }
        let resultsContents = results.map { $0.content }
        XCTAssertEqual(resultsContents, historyContents, "Empty search should return same as getHistory()")
    }
    
    // MARK: - Test: History Persistence (Save and Load from JSON)
    
    func testHistorySavedToJsonAfterChange() {
        // Given
        let manager = createManager()
        
        // When - add content
        simulateClipboardChange(content: "Saved content", in: manager)
        
        // Then - verify file was created
        XCTAssertTrue(mockFileSystem.createFileCalls.count > 0, "Should have attempted to save to file")
        
        let lastSaveCall = mockFileSystem.createFileCalls.last
        XCTAssertEqual(lastSaveCall?.path, storageURL.path, "Should save to correct path")
        
        // Verify the saved data is valid JSON
        if let savedData = lastSaveCall?.data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loadedItems = try? decoder.decode([ClipboardItem].self, from: savedData)
            XCTAssertNotNil(loadedItems, "Saved data should be valid JSON")
            XCTAssertEqual(loadedItems?.count, 1)
            XCTAssertEqual(loadedItems?.first?.content, "Saved content")
        } else {
            XCTFail("No data was saved")
        }
    }
    
    func testHistoryLoadedFromJsonOnInit() {
        // Given - pre-populate history file
        let existingItems = [
            ClipboardItem(content: "Existing item 1"),
            ClipboardItem(content: "Existing item 2")
        ]
        let existingData = encodeHistory(existingItems)
        mockFileSystem.addFile(at: storageURL.path, contents: existingData)
        
        // When - create manager
        let manager = createManager()
        
        // Then - history should be loaded
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 2, "Should load existing history from file")
        XCTAssertEqual(history[0].content, "Existing item 1")
        XCTAssertEqual(history[1].content, "Existing item 2")
    }
    
    func testHistoryPersistsAcrossManagerInstances() {
        // Given - create first manager and add content
        let manager1 = createManager()
        simulateClipboardChange(content: "Persisted content", in: manager1)
        
        // When - create second manager (simulating app restart)
        let manager2 = ClipboardManager(pasteboard: MockPasteboard(), fileSystem: mockFileSystem)
        
        // Then - second manager should have the persisted content
        let history = manager2.getHistory()
        XCTAssertEqual(history.count, 1, "Should persist history across instances")
        XCTAssertEqual(history.first?.content, "Persisted content")
    }
    
    func testNoHistoryFileReturnsEmptyHistory() {
        // Given - no history file exists (default mock state)
        
        // When
        let manager = createManager()
        
        // Then
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 0, "Should return empty history when no file exists")
    }
    
    func testCorruptedHistoryFileHandledGracefully() {
        // Given - corrupted JSON in history file
        let corruptedData = "not valid json {{{".data(using: .utf8)!
        mockFileSystem.addFile(at: storageURL.path, contents: corruptedData)
        
        // When - create manager (should not crash)
        let manager = createManager()
        
        // Then - history should be empty
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 0, "Should return empty history when file is corrupted")
    }
    
    // MARK: - Test: Empty/Non-Text Clipboard Content is Ignored
    
    func testEmptyClipboardContentIsIgnored() {
        // Given
        let manager = createManager()
        
        // When - clipboard change with empty string
        mockPasteboard.simulateExternalChange(content: "")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        
        // Then
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 0, "Empty clipboard content should be ignored")
    }
    
    func testNilClipboardContentIsIgnored() {
        // Given
        let manager = createManager()
        
        // When - clipboard change with nil (simulating non-text content like images)
        mockPasteboard.simulateExternalChange(content: nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        
        // Then
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 0, "Nil clipboard content should be ignored")
    }
    
    func testWhitespaceOnlyContentIsCaptured() {
        // Given
        let manager = createManager()
        
        // When - clipboard with whitespace (technically not empty)
        simulateClipboardChange(content: "   ", in: manager)
        
        // Then - whitespace-only content is still captured (it's valid text)
        let history = manager.getHistory()
        XCTAssertEqual(history.count, 1, "Whitespace content should be captured")
        XCTAssertEqual(history.first?.content, "   ")
    }
    
    // MARK: - Test: Application Support Directory Creation
    
    func testAppleBoxDirectoryCreatedIfNotExists() {
        // Given - directory doesn't exist (default mock state)
        
        // When
        _ = createManager()
        
        // Then - should attempt to create directory
        XCTAssertTrue(mockFileSystem.createDirectoryCalls.count > 0, "Should attempt to create directory")
        let createCall = mockFileSystem.createDirectoryCalls.first
        XCTAssertTrue(createCall?.url.path.contains("AppleBox") == true, "Should create AppleBox directory")
        XCTAssertTrue(createCall?.createIntermediates == true, "Should create intermediate directories")
    }
    
    func testDirectoryNotRecreatedIfExists() {
        // Given - directory already exists
        let appSupportURL = URL(fileURLWithPath: "/Users/testuser/Library/Application Support")
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        mockFileSystem.addFile(at: appDirectory.path, isDirectory: true)
        
        // When
        _ = createManager()
        
        // Then - should not attempt to create directory
        XCTAssertEqual(mockFileSystem.createDirectoryCalls.count, 0, "Should not create directory if it exists")
    }
    
    // MARK: - Test: Exact Substring Ranking for Bracketed Queries
    
    func testExactSubstringRankedAboveScatteredMatch() {
        // Given - pre-populate history with items where one has exact "[main]" and another
        // only supports scattered subsequence matching
        let itemWithExact = ClipboardItem(content: "[13:52:52] [~/source/me/dotf][main] (~6, ?1)")
        // This item has all characters of "[main]" but scattered: [, m, a, i, n, ]
        // [log] message about interesting news] - has [ m a i n ]
        let itemWithScattered = ClipboardItem(content: "[log] message about interesting news]")
        
        // Order in history: scattered first, exact second (to verify ranking changes order)
        let existingItems = [itemWithScattered, itemWithExact]
        let existingData = encodeHistory(existingItems)
        mockFileSystem.addFile(at: storageURL.path, contents: existingData)
        
        // When
        let manager = createManager()
        let results = manager.searchHistoryWithMatches(query: "[main]")
        
        // Then - exact substring match should be ranked first
        XCTAssertEqual(results.count, 2, "Both items should match")
        XCTAssertEqual(results[0].item.content, itemWithExact.content, "Exact substring match should be ranked first")
        XCTAssertEqual(results[1].item.content, itemWithScattered.content, "Scattered match should be ranked second")
        
        // Verify the exact match has contiguous indices
        let exactIndices = results[0].matchedIndices
        for i in 1..<exactIndices.count {
            XCTAssertEqual(
                exactIndices[i],
                exactIndices[i - 1] + 1,
                "Exact substring indices should be contiguous"
            )
        }
    }
    
    func testMatchedIndicesPointToCorrectSubstring() {
        // Given
        let item = ClipboardItem(content: "[13:52:52] [~/source/me/dotf][main] (~6, ?1)")
        let existingData = encodeHistory([item])
        mockFileSystem.addFile(at: storageURL.path, contents: existingData)
        
        // When
        let manager = createManager()
        let results = manager.searchHistoryWithMatches(query: "[main]")
        
        // Then
        XCTAssertEqual(results.count, 1)
        
        let indices = results[0].matchedIndices
        XCTAssertEqual(indices.count, 6, "Should have 6 matched indices for '[main]'")
        
        // Extract the matched substring using indices
        let content = results[0].item.content
        let startIdx = indices.first!
        let endIdx = indices.last!
        let startStringIdx = content.index(content.startIndex, offsetBy: startIdx)
        let endStringIdx = content.index(content.startIndex, offsetBy: endIdx + 1)
        let matchedSubstring = String(content[startStringIdx..<endStringIdx])
        
        XCTAssertEqual(matchedSubstring, "[main]", "Indices should point to the '[main]' substring")
    }
    
    func testMultipleExactSubstringMatchesRankedByRecency() {
        // Given - two items both containing exact "[main]"
        let olderItem = ClipboardItem(content: "older [main] item")
        let newerItem = ClipboardItem(content: "newer [main] item")
        
        // History is most-recent-first, so newer is at index 0
        let existingItems = [newerItem, olderItem]
        let existingData = encodeHistory(existingItems)
        mockFileSystem.addFile(at: storageURL.path, contents: existingData)
        
        // When
        let manager = createManager()
        let results = manager.searchHistoryWithMatches(query: "[main]")
        
        // Then - both match with same score (exact substring), so recency should break tie
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].item.content, newerItem.content, "Newer item should be first")
        XCTAssertEqual(results[1].item.content, olderItem.content, "Older item should be second")
    }
}
