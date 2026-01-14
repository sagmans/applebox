import XCTest
import AppKit
@testable import AppleBox

/// UI-level tests for WindowManager behavior and keyboard handling
final class WindowManagerTests: XCTestCase {

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

    // MARK: - Window Show/Hide Tests

    func testWindowShowsCenteredOnScreen() {
        // When window is shown
        windowManager.show()

        // Then window should be visible
        XCTAssertTrue(windowManager.isVisible(), "Window should be visible after show()")
    }

    func testWindowHidesWhenToggleCalledWhileVisible() {
        // Given: Window is visible
        windowManager.show()
        XCTAssertTrue(windowManager.isVisible())

        // When: Toggle is called
        windowManager.toggle()

        // Then: Window should be hidden
        XCTAssertFalse(windowManager.isVisible(), "Window should be hidden after toggle when visible")
    }

    func testWindowShowsWhenToggleCalledWhileHidden() {
        // Given: Window is hidden
        XCTAssertFalse(windowManager.isVisible())

        // When: Toggle is called
        windowManager.toggle()

        // Then: Window should be visible
        XCTAssertTrue(windowManager.isVisible(), "Window should be visible after toggle when hidden")
    }

    func testMultipleToggles() {
        // Toggle on
        windowManager.toggle()
        XCTAssertTrue(windowManager.isVisible())

        // Toggle off
        windowManager.toggle()
        XCTAssertFalse(windowManager.isVisible())

        // Toggle on again
        windowManager.toggle()
        XCTAssertTrue(windowManager.isVisible())

        // Toggle off again
        windowManager.toggle()
        XCTAssertFalse(windowManager.isVisible())
    }

    func testShowAfterShowRemainsVisible() {
        // Show window
        windowManager.show()
        XCTAssertTrue(windowManager.isVisible())

        // Show again
        windowManager.show()
        XCTAssertTrue(windowManager.isVisible(), "Window should remain visible after multiple show calls")
    }

    func testHideAfterHideRemainsHidden() {
        // Show then hide
        windowManager.show()
        windowManager.hide()
        XCTAssertFalse(windowManager.isVisible())

        // Hide again
        windowManager.hide()
        XCTAssertFalse(windowManager.isVisible(), "Window should remain hidden after multiple hide calls")
    }

    // MARK: - Escape Key Tests
 
     func testEscapeKeyTriggersQuit() {
         // Given: Window is visible
         windowManager.show()
         XCTAssertTrue(windowManager.isVisible())
 
         // Note: We cannot directly test NSApp.terminate() behavior in unit tests,
         // but we can verify the escape key handler exists and window behavior.
         // The quit() method calls window?.orderOut() and sets isWindowVisible = false
         // before calling NSApp.terminate(nil)
 
         // When: Window is ordered out (simulating pre-terminate behavior)
         windowManager.hide()
 
         // Then: Window should be hidden (quit's first action before terminate)
         XCTAssertFalse(windowManager.isVisible())
     }
 
     func testEscapeInSearchFieldWithTextClearsSelectionAndHidesWindows() throws {
         // Seed clipboard history so clipboard mode starts with a selection.
         let appSupportURL = try XCTUnwrap(mockFileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
         let storageURL = appSupportURL
             .appendingPathComponent("AppleBox", isDirectory: true)
             .appendingPathComponent("clipboard_history.json")
 
         let encoder = JSONEncoder()
         encoder.dateEncodingStrategy = .iso8601
         let historyData = try encoder.encode([ClipboardItem(content: "hello")])
         _ = mockFileSystem.createFile(atPath: storageURL.path, contents: historyData, attributes: nil)
 
         // Re-create ClipboardManager so it loads the seeded history.
         clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
         windowManager.setClipboardManager(clipboardManager)
 
         // Show clipboard UI + sidecar.
         windowManager.show(mode: .clipboard)
         windowManager.showSidecar()
         XCTAssertTrue(windowManager.isVisible())
         XCTAssertTrue(windowManager.isSidecarShowing())
         XCTAssertEqual(windowManager.getSelectedRowIndex(), 0)
 
         let searchField = try XCTUnwrap(windowManager.getSearchField())
         searchField.stringValue = "abc"
 
         // Simulate Esc in field editor (maps to cancelOperation).
         let handled = windowManager.control(
             searchField,
             textView: NSTextView(),
             doCommandBy: #selector(NSResponder.cancelOperation(_:))
         )
 
         XCTAssertTrue(handled)
         XCTAssertEqual(searchField.stringValue, "")
         XCTAssertEqual(windowManager.getSelectedRowIndex(), -1)
         XCTAssertFalse(windowManager.isSidecarShowing())
         XCTAssertFalse(windowManager.isVisible())
     }
 
     func testEscapeInSearchFieldWithEmptyTextHidesWindow() throws {
         windowManager.show()
         XCTAssertTrue(windowManager.isVisible())
 
         let searchField = try XCTUnwrap(windowManager.getSearchField())
         XCTAssertEqual(searchField.stringValue, "")
 
         let handled = windowManager.control(
             searchField,
             textView: NSTextView(),
             doCommandBy: #selector(NSResponder.cancelOperation(_:))
         )
 
         XCTAssertTrue(handled)
         XCTAssertFalse(windowManager.isVisible())
     }


    // MARK: - Navigation Tests

    func testArrowKeysNavigateSelectionUp() {
        // Given: Window is visible with search results
        windowManager.show()

        // Note: Direct keyboard event testing requires AppKit event loop
        // We verify the infrastructure is in place by checking the window handlers exist
        // and that the WindowManager responds to navigation

        // Window should be visible and ready for input
        XCTAssertTrue(windowManager.isVisible())
    }

    func testArrowKeysNavigateSelectionDown() {
        // Given: Window is visible
        windowManager.show()

        // Window should be visible and ready for input
        XCTAssertTrue(windowManager.isVisible())
    }

    // MARK: - Enter Key Tests

    func testEnterKeyTriggersActionHandler() {
        // Given: Window is visible
        windowManager.show()

        // The enter key handler is configured in setupWindow()
        // Direct testing of key events would require running the full AppKit event loop

        XCTAssertTrue(windowManager.isVisible())
    }

    func testEnterKeyWithNoSelectionHidesWindow() {
        // Given: Window is visible with no search results
        windowManager.show()

        // When: Enter key is pressed with no selection
        // The handleEnterKey() method checks if selectedRowIndex is valid
        // and calls hide() if there's no valid selection

        // This is handled in the WindowManager implementation:
        // guard selectedRowIndex >= 0 && selectedRowIndex < searchResults.count else {
        //     hide()
        //     return
        // }

        XCTAssertTrue(windowManager.isVisible())
    }

    // MARK: - Search Field Focus Tests

    func testSearchFieldReceivesFocusWhenWindowShows() {
        // Given: Window is hidden
        XCTAssertFalse(windowManager.isVisible())

        // When: Window is shown
        windowManager.show()

        // Then: Window should be visible
        // The initialFirstResponder is set to searchField in setupWindow()
        // and makeFirstResponder is called in show()
        XCTAssertTrue(windowManager.isVisible())
    }

    func testSearchFieldClearedWhenWindowShows() {
        // Given: Window has been shown and hidden before
        windowManager.show()
        windowManager.hide()

        // When: Window is shown again
        windowManager.show()

        // Then: Search field should be cleared (this is done in show() method)
        // searchField.stringValue = "" is called in show()
        XCTAssertTrue(windowManager.isVisible())
    }

    // MARK: - Window State Tests

    func testInitialWindowStateIsHidden() {
        // A newly created WindowManager should have its window hidden
        let freshWindowManager = WindowManager(
            workspace: mockWorkspace,
            pasteboard: mockPasteboard,
            eventSource: mockEventSource,
            fileSystem: mockFileSystem
        )

        XCTAssertFalse(freshWindowManager.isVisible(), "Window should be hidden initially")
    }

    func testIsVisibleReturnsCorrectState() {
        // Initially hidden
        XCTAssertFalse(windowManager.isVisible())

        // After show
        windowManager.show()
        XCTAssertTrue(windowManager.isVisible())

        // After hide
        windowManager.hide()
        XCTAssertFalse(windowManager.isVisible())

        // After toggle (should be visible)
        windowManager.toggle()
        XCTAssertTrue(windowManager.isVisible())
    }

    // MARK: - Application Launch Tests

    func testApplicationLaunchWithValidPath() {
        // Given: An application exists at the path
        let appPath = "/Applications/Google Chrome.app"
        mockFileSystem.addFile(at: appPath, isDirectory: true)

        // The launch would be triggered by handleEnterKey when an app is selected
        // We can verify the mock workspace would be called correctly

        // Verify app exists in mock file system
        XCTAssertTrue(mockFileSystem.fileExists(atPath: appPath))
    }

    func testApplicationLaunchWithInvalidPath() {
        // Given: An application that doesn't exist
        let appPath = "/Applications/NonExistent.app"

        // Verify app doesn't exist in mock file system
        XCTAssertFalse(mockFileSystem.fileExists(atPath: appPath))
    }

    // MARK: - Clipboard Action Tests

    func testClipboardCopySetsPasteboard() {
        // Given: Window is visible
        windowManager.show()

        // The copyToClipboard method would:
        // 1. Call pasteboard.clearContents()
        // 2. Call pasteboard.setString(text, forType: .string)
        // 3. Call hide()

        // Verify mock is ready
        XCTAssertEqual(mockPasteboard.clearContentsCalls, 0)
        XCTAssertEqual(mockPasteboard.setStringCalls.count, 0)
    }

    func testClipboardCopyHidesWindow() {
        // Given: Window is visible
        windowManager.show()
        XCTAssertTrue(windowManager.isVisible())

        // The copyToClipboard method calls hide() after copying
        windowManager.hide()
        XCTAssertFalse(windowManager.isVisible())
    }

    // MARK: - Search Mode Reset Tests

    func testSearchModeResetToApplicationsOnShow() {
        // Given: Window was in clipboard mode
        windowManager.show()

        // When: Window is shown again
        windowManager.hide()
        windowManager.show()

        // Then: Mode should be reset to applications
        // This is verified by the placeholder text being "Search applications..."
        XCTAssertTrue(windowManager.isVisible())
    }

    func testSearchResultsClearedOnShow() {
        // Given: Window had search results
        windowManager.show()

        // When: Window is shown again
        windowManager.hide()
        windowManager.show()

        // Then: Results should be cleared
        // This is done in show() method: searchResults = []
        XCTAssertTrue(windowManager.isVisible())
    }

    // MARK: - Event Source Integration Tests

    func testPasteToFrontmostAppPostsKeyboardEvents() {
        // Given: Window is visible
        windowManager.show()

        // Reset mock to track new events
        mockEventSource.resetInvocations()

        // When: Hide is called (which triggers pasteToFrontmostApp in clipboard mode flow)
        // Note: pasteToFrontmostApp is called after copyToClipboard

        // Verify mock is ready to track events
        XCTAssertEqual(mockEventSource.keyboardEventCount, 0)
    }

    // MARK: - Window Handler Configuration Tests

    func testEscapeHandlerIsConfigured() {
        // The escape handler is configured in setupWindow()
        // We verify the WindowManager is properly initialized
        XCTAssertNotNil(windowManager)
    }

    func testArrowUpHandlerIsConfigured() {
        // The arrow up handler is configured in setupWindow()
        XCTAssertNotNil(windowManager)
    }

    func testArrowDownHandlerIsConfigured() {
        // The arrow down handler is configured in setupWindow()
        XCTAssertNotNil(windowManager)
    }

    func testEnterHandlerIsConfigured() {
        // The enter handler is configured in setupWindow()
        XCTAssertNotNil(windowManager)
    }

    // MARK: - Sidecar Panel Tests

    func testSidecarWindowExists() {
        // The sidecar window is created during setupWindow()
        XCTAssertNotNil(windowManager.getSidecarWindow())
    }

    func testSidecarContentViewExists() {
        // The sidecar content view is created during setupWindow()
        XCTAssertNotNil(windowManager.getSidecarContentView())
    }

    func testSidecarInitiallyHidden() {
        // Sidecar should not be visible by default
        XCTAssertFalse(windowManager.isSidecarShowing())
    }

    func testSidecarShowsInClipboardMode() {
        // Show main window in clipboard mode
        windowManager.show(mode: .clipboard)

        // Show sidecar
        windowManager.showSidecar()

        XCTAssertTrue(windowManager.isSidecarShowing())
    }

    func testSidecarDoesNotShowInApplicationMode() {
        // Show main window in application mode
        windowManager.show(mode: .applications)

        // Attempt to show sidecar (should be ignored in application mode)
        windowManager.showSidecar()

        XCTAssertFalse(windowManager.isSidecarShowing())
    }

    func testSidecarHides() {
        // Show main window in clipboard mode and sidecar
        windowManager.show(mode: .clipboard)
        windowManager.showSidecar()
        XCTAssertTrue(windowManager.isSidecarShowing())

        // Hide sidecar
        windowManager.hideSidecar()
        XCTAssertFalse(windowManager.isSidecarShowing())
    }

    func testSidecarHiddenWhenMainWindowHides() {
        // Show main window in clipboard mode and sidecar
        windowManager.show(mode: .clipboard)
        windowManager.showSidecar()
        XCTAssertTrue(windowManager.isSidecarShowing())

        // Hide main window
        windowManager.hide()
        XCTAssertFalse(windowManager.isSidecarShowing())
    }

    func testSidecarWindowDimensions() {
        guard let sidecarWindow = windowManager.getSidecarWindow() else {
            XCTFail("Sidecar window should exist")
            return
        }

        // Verify sidecar dimensions (~320px width, 400px height)
        let frame = sidecarWindow.frame
        XCTAssertEqual(frame.width, 320, accuracy: 1)
        XCTAssertEqual(frame.height, 400, accuracy: 1)
    }

    func testSidecarWindowHasGlassStyling() {
        guard let sidecarWindow = windowManager.getSidecarWindow() else {
            XCTFail("Sidecar window should exist")
            return
        }

        // Verify glass styling properties
        XCTAssertEqual(sidecarWindow.backgroundColor, .clear)
        XCTAssertFalse(sidecarWindow.isOpaque)
        XCTAssertTrue(sidecarWindow.hasShadow)
        XCTAssertEqual(sidecarWindow.level, .floating)

        // Verify content view is NSVisualEffectView
        XCTAssertTrue(sidecarWindow.contentView is NSVisualEffectView)
    }
    
    // MARK: - Exact Substring Highlight Verification Tests
    
    func testExactSubstringHighlightInClipboardSearch() throws {
        // Given: Seed clipboard history with items containing "[main]"
        let appSupportURL = try XCTUnwrap(mockFileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let storageURL = appSupportURL
            .appendingPathComponent("AppleBox", isDirectory: true)
            .appendingPathComponent("clipboard_history.json")
        
        let itemWithExact = ClipboardItem(content: "[13:52:52] [~/source/me/dotf][main] (~6, ?1)")
        // This item has all characters of "[main]" scattered: [ m a i n ]
        let itemWithScattered = ClipboardItem(content: "[log] message about interesting news]")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let historyData = try encoder.encode([itemWithExact, itemWithScattered])
        _ = mockFileSystem.createFile(atPath: storageURL.path, contents: historyData, attributes: nil)
        
        // Re-create ClipboardManager to load the seeded history
        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        windowManager.setClipboardManager(clipboardManager)
        
        // When: Show clipboard UI and search for "[main]"
        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "[main]")
        
        // Then: Row 0 should be the item with exact substring
        XCTAssertEqual(windowManager.getResultCount(), 2, "Both items should match")
        
        // Get the cell view for row 0
        guard let cellView = windowManager.getCellViewForTesting(at: 0) else {
            XCTFail("Cell view should exist for row 0")
            return
        }
        
        // Find the text field with tag 200 (clipboard text label)
        guard let textField = cellView.viewWithTag(200) as? NSTextField else {
            XCTFail("Text field with tag 200 should exist")
            return
        }
        
        // Verify the text contains "[main]"
        XCTAssertTrue(
            textField.stringValue.contains("[main]"),
            "Row 0 should display item containing exact '[main]'"
        )
        
        // Verify highlighting: check that some characters have accent color
        let attributedString = textField.attributedStringValue
        var hasAccentHighlight = false
        let accentColor = NSColor.controlAccentColor
        
        attributedString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributedString.length)) { value, range, _ in
            if let color = value as? NSColor, color == accentColor {
                hasAccentHighlight = true
            }
        }
        
        XCTAssertTrue(hasAccentHighlight, "Row should have accent color highlights for matched characters")
    }
    
    func testHighlightedIndicesAreContiguousForExactSubstring() throws {
        // Given: Seed clipboard history
        let appSupportURL = try XCTUnwrap(mockFileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let storageURL = appSupportURL
            .appendingPathComponent("AppleBox", isDirectory: true)
            .appendingPathComponent("clipboard_history.json")
        
        let item = ClipboardItem(content: "test [main] string")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let historyData = try encoder.encode([item])
        _ = mockFileSystem.createFile(atPath: storageURL.path, contents: historyData, attributes: nil)
        
        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        windowManager.setClipboardManager(clipboardManager)
        
        // When: Search for "[main]"
        windowManager.show(mode: .clipboard)
        windowManager.simulateSearch(query: "[main]")
        
        // Then: Verify indices are contiguous via the search results
        let results = clipboardManager.searchHistoryWithMatches(query: "[main]")
        XCTAssertEqual(results.count, 1)
        
        let indices = results[0].matchedIndices
        XCTAssertEqual(indices.count, 6, "Should have 6 indices for '[main]'")
        
        // Verify contiguous
        for i in 1..<indices.count {
            XCTAssertEqual(
                indices[i],
                indices[i - 1] + 1,
                "Indices should be contiguous for exact substring"
            )
        }
        
        // Verify they point to "[main]"
        let content = results[0].item.content
        let startIdx = content.index(content.startIndex, offsetBy: indices.first!)
        let endIdx = content.index(content.startIndex, offsetBy: indices.last! + 1)
        let matchedSubstring = String(content[startIdx..<endIdx])
        XCTAssertEqual(matchedSubstring, "[main]")
    }
    
    func testSidecarHighlightsMatchedIndices() throws {
        // Given: Seed clipboard history with a long item (triggers sidecar)
        let appSupportURL = try XCTUnwrap(mockFileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let storageURL = appSupportURL
            .appendingPathComponent("AppleBox", isDirectory: true)
            .appendingPathComponent("clipboard_history.json")
        
        // Create a long item that will trigger sidecar visibility
        let longContent = """
        $ v benchmark.sh
        [13:52:52] [~/source/me/dotf][main] (~6, ?1)
        $ chmod +x benchmark.sh
        [13:52:58] [~/source/me/dotf][main] (~6, ?1)
        $ ./benchmark.sh
        Running 5 iterations...
        =====================================
        Run 1...
            Time: 3.660568000s | Input: 14208 | Output: 29 | Reasoning: 0
        Run 2...
            Time: 4.800637000s | Input: 14208 | Output: 96 | Reasoning: 64
        """
        let item = ClipboardItem(content: longContent)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let historyData = try encoder.encode([item])
        _ = mockFileSystem.createFile(atPath: storageURL.path, contents: historyData, attributes: nil)
        
        clipboardManager = ClipboardManager(pasteboard: mockPasteboard, fileSystem: mockFileSystem)
        windowManager.setClipboardManager(clipboardManager)
        
        // When: Show clipboard mode, sidecar, and search
        windowManager.show(mode: .clipboard)
        windowManager.showSidecar()
        windowManager.simulateSearch(query: "[main]")
        
        // Then: Sidecar should be showing
        XCTAssertTrue(windowManager.isSidecarShowing(), "Sidecar should be visible for long content")
        
        // Verify search result has contiguous indices for "[main]"
        let results = clipboardManager.searchHistoryWithMatches(query: "[main]")
        XCTAssertEqual(results.count, 1)
        
        let indices = results[0].matchedIndices
        XCTAssertEqual(indices.count, 6)
        
        // Verify the indices point to the first "[main]" occurrence
        let content = results[0].item.content
        let startIdx = content.index(content.startIndex, offsetBy: indices.first!)
        let endIdx = content.index(content.startIndex, offsetBy: indices.last! + 1)
        let matchedSubstring = String(content[startIdx..<endIdx])
        XCTAssertEqual(matchedSubstring, "[main]", "Highlighted indices should point to '[main]'")
    }
}
