import AppKit
import CoreGraphics

// MARK: - Search Mode
enum SearchMode {
    case applications
    case clipboard
}

// Result type for clipboard search
struct ClipboardSearchResult {
    let item: ClipboardItem
    let relevanceScore: Int
}



// Custom NSWindow that handles key events
class AppleBoxWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    var arrowUpHandler: (() -> Void)?
    var arrowDownHandler: (() -> Void)?
    var enterHandler: (() -> Void)?

    override var canBecomeKey: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            escapeHandler?()
        case 126: // Up arrow
            arrowUpHandler?()
        case 125: // Down arrow
            arrowDownHandler?()
        case 36: // Enter
            enterHandler?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // Ensure Esc works even when a control (e.g. NSSearchField) consumes keyDown.
        escapeHandler?()
    }
}

class WindowManager: NSObject {
    private var window: AppleBoxWindow?
    private var isWindowVisible = false
    private var searchField: NSSearchField?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?

    private var searchService: SearchService?
    private var searchResults: [SearchResult] = []
    private var selectedRowIndex: Int = -1

    // Clipboard support
    private var clipboardManager: ClipboardManager?
    private var clipboardResults: [ClipboardSearchResult] = []
    private var searchMode: SearchMode = .applications
    private let clipboardTrigger = ">" // Trigger to switch to clipboard mode

    // Injected dependencies
    private let workspace: WorkspaceProtocol
    private let pasteboard: PasteboardProtocol
    private let eventSource: EventSourceProtocol
    private let fileSystem: FileSystemProtocol

    init(
        workspace: WorkspaceProtocol = SystemWorkspace(),
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        eventSource: EventSourceProtocol = SystemEventSource(),
        fileSystem: FileSystemProtocol = SystemFileManager()
    ) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.eventSource = eventSource
        self.fileSystem = fileSystem
        super.init()
        setupWindow()
    }

    func setSearchService(_ service: SearchService) {
        self.searchService = service
    }

    func setClipboardManager(_ manager: ClipboardManager) {
        self.clipboardManager = manager
    }

    private func setupWindow() {
        // Create a window for search bar and results
        let window = AppleBoxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.level = .floating
        
        // Accessibility for window
        window.setAccessibilityIdentifier("AppleBoxWindow")
        window.setAccessibilityLabel("AppleBox Launcher")
        window.setAccessibilityHelp("Quick launcher for applications and clipboard history")

        // Handle key events
        window.escapeHandler = { [weak self] in
            self?.quit()
        }

        window.arrowUpHandler = { [weak self] in
            self?.navigateResults(direction: -1)
        }

        window.arrowDownHandler = { [weak self] in
            self?.navigateResults(direction: 1)
        }

        window.enterHandler = { [weak self] in
            self?.handleEnterKey()
        }

        // Create content view
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = contentView

        // Create search field
        let searchField = NSSearchField(frame: NSRect(x: 20, y: 350, width: 560, height: 30))
        searchField.placeholderString = "Search applications..."
        searchField.font = NSFont.systemFont(ofSize: 16)
        searchField.target = self
        searchField.action = #selector(handleSearch(_:))
        searchField.delegate = self  // For arrow key handling
        
        // Accessibility for search field
        searchField.setAccessibilityIdentifier("AppleBoxSearchField")
        searchField.setAccessibilityLabel("Search Field")
        searchField.setAccessibilityHelp("Type to search for applications. Type > to search clipboard history.")

        contentView.addSubview(searchField)
        self.searchField = searchField

        // Create scroll view for results
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 560, height: 320))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        // Create table view
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.style = .plain
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        
        // Accessibility for table view
        tableView.setAccessibilityIdentifier("AppleBoxResultsTable")
        tableView.setAccessibilityLabel("Search Results")
        tableView.setAccessibilityHelp("Use arrow keys to navigate results, Enter to select.")

        // Create single text column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.width = 560
        column.dataCell = NSTextFieldCell()
        tableView.addTableColumn(column)

        // Set up data source and delegate
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        self.tableView = tableView
        self.scrollView = scrollView

        // Set window delegate
        window.delegate = self
        window.initialFirstResponder = searchField

        self.window = window
    }

    func toggle() {
        if isWindowVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let window = window else { return }

        // Center on the active screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame

            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.midY - windowFrame.height / 2

            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Reset to application mode
        searchMode = .applications

        // Focus the search field and clear it
        if let searchField = searchField {
            searchField.stringValue = ""
            searchField.placeholderString = "Search applications..."
            window.makeFirstResponder(searchField)
        }

        // Reset search state
        searchResults = []
        clipboardResults = []
        selectedRowIndex = -1
        tableView?.reloadData()

        isWindowVisible = true
        print("Window shown")
    }

    func hide() {
        window?.orderOut(nil)
        NSApp.hide(nil)
        isWindowVisible = false
        print("Window hidden")
    }

    func quit() {
        window?.orderOut(nil)
        isWindowVisible = false
        NSApp.terminate(nil)
    }

    @objc private func handleSearch(_ sender: NSSearchField) {
        let query = sender.stringValue
        print("Search: \(query)")

        // Check for clipboard mode trigger
        if query == clipboardTrigger {
            searchMode = .clipboard
            sender.placeholderString = "Search clipboard history..."
            clipboardResults = []
            // Show all clipboard history
            if let manager = clipboardManager {
                let history = manager.getHistory()
                clipboardResults = history.map { ClipboardSearchResult(item: $0, relevanceScore: 0) }
            }
            selectedRowIndex = clipboardResults.isEmpty ? -1 : 0
        } else if searchMode == .clipboard && query.hasPrefix(clipboardTrigger) {
            // Filter clipboard history
            let searchQuery = String(query.dropFirst())
            if searchQuery.isEmpty {
                // Show all history when just the trigger is typed
                if let manager = clipboardManager {
                    let history = manager.getHistory()
                    clipboardResults = history.map { ClipboardSearchResult(item: $0, relevanceScore: 0) }
                }
            } else {
                // Filter clipboard history
                if let manager = clipboardManager {
                    let filtered = manager.searchHistory(query: searchQuery)
                    clipboardResults = filtered.map { ClipboardSearchResult(item: $0, relevanceScore: 0) }
                }
            }
            selectedRowIndex = clipboardResults.isEmpty ? -1 : 0
        } else {
            // Application search mode
            searchMode = .applications
            sender.placeholderString = "Search applications..."
            guard let searchService = searchService else { return }

            if query.isEmpty {
                searchResults = []
                selectedRowIndex = -1
            } else {
                searchResults = searchService.search(query)
                selectedRowIndex = searchResults.isEmpty ? -1 : 0
            }
        }

        tableView?.reloadData()

        // Scroll to top
        if let scrollView = scrollView, let documentView = scrollView.documentView {
            documentView.scroll(NSPoint(x: 0, y: documentView.bounds.height))
        }
    }

    private func navigateResults(direction: Int) {
        // Determine which result set to use based on mode
        let resultCount = searchMode == .clipboard ? clipboardResults.count : searchResults.count
        guard resultCount > 0 else { return }

        let newIndex = selectedRowIndex + direction

        // Handle navigation boundaries without wrapping
        if newIndex < 0 {
            // Going up from first element (or no selection) - focus search field
            selectedRowIndex = -1
            tableView?.deselectAll(nil)
            window?.makeFirstResponder(searchField)
            print("Focus returned to search field")
            return
        } else if newIndex >= resultCount {
            // At last element, don't wrap - stay at last
            return
        }

        selectedRowIndex = newIndex
        tableView?.selectRowIndexes(IndexSet(integer: selectedRowIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(selectedRowIndex)

        if searchMode == .clipboard {
            print("Selected: \(selectedRowIndex) - \(clipboardResults[selectedRowIndex].item.content)")
        } else {
            print("Selected: \(selectedRowIndex) - \(searchResults[selectedRowIndex].application.name)")
        }
    }

    private func handleEnterKey() {
        if searchMode == .clipboard {
            guard selectedRowIndex >= 0 && selectedRowIndex < clipboardResults.count else {
                hide()
                return
            }

            let item = clipboardResults[selectedRowIndex].item
            copyToClipboard(item.content)
        } else {
            guard selectedRowIndex >= 0 && selectedRowIndex < searchResults.count else {
                hide()
                return
            }

            let appInfo = searchResults[selectedRowIndex].application
            launchApplication(appInfo)
        }
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        let clickedRow = sender.clickedRow

        if searchMode == .clipboard {
            if clickedRow >= 0 && clickedRow < clipboardResults.count {
                let item = clipboardResults[clickedRow].item
                copyToClipboard(item.content)
            }
        } else {
            if clickedRow >= 0 && clickedRow < searchResults.count {
                let appInfo = searchResults[clickedRow].application
                launchApplication(appInfo)
            }
        }
    }

    /// Launch an application using WorkspaceProtocol
    /// - Parameter appInfo: The application information containing the bundle path
    private func launchApplication(_ appInfo: ApplicationInfo) {
        let bundlePath = appInfo.bundlePath
        let appUrl = URL(fileURLWithPath: bundlePath)

        print("Launching: \(appInfo.name) at \(bundlePath)")

        // Check if the app bundle exists
        guard fileSystem.fileExists(atPath: bundlePath) else {
            print("Error: Application bundle not found at \(bundlePath)")
            // Show error to user (optional - for now just print)
            return
        }

        // Launch the application
        let config = NSWorkspace.OpenConfiguration()
        workspace.openApplication(at: appUrl, configuration: config) { [weak self] app, error in
            if let error = error {
                print("Error launching \(appInfo.name): \(error.localizedDescription)")
                // Handle error gracefully - could show alert here
                return
            }

            if let app = app {
                print("Successfully launched: \(app.localizedName ?? appInfo.name)")
            }

            // Close the window after launching (on main thread)
            DispatchQueue.main.async {
                self?.hide()
            }
        }
    }

    /// Copy text to the clipboard and paste it
    /// - Parameter text: The text to copy
    private func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("Copied to clipboard: \(text)")

        // Close the window after copying
        hide()
        
        // Auto-paste to frontmost app
        pasteToFrontmostApp()
    }

    /// Simulate Cmd+V to paste content
    private func pasteToFrontmostApp() {
        // Wait briefly for the window to hide and previous app to activate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // kVK_ANSI_V is 0x09
            let vKeyCode: CGKeyCode = 0x09
            
            // Post key down with Command flag
            self.eventSource.postKeyboardEvent(keyCode: vKeyCode, keyDown: true, flags: .maskCommand)
            // Post key up with Command flag
            self.eventSource.postKeyboardEvent(keyCode: vKeyCode, keyDown: false, flags: .maskCommand)
            
            print("Simulated Cmd+V")
        }
    }

    func isVisible() -> Bool {
        return isWindowVisible
    }

    // MARK: - Test Helpers
    
    /// Returns the current search mode (for testing)
    func getCurrentSearchMode() -> SearchMode {
        return searchMode
    }
    
    /// Returns the current placeholder text (for testing)
    func getPlaceholderText() -> String? {
        return searchField?.placeholderString
    }
    
    /// Returns the number of results currently displayed (for testing)
    func getResultCount() -> Int {
        return searchMode == .clipboard ? clipboardResults.count : searchResults.count
    }
    
    /// Returns the current search text (for testing)
    func getSearchText() -> String? {
        return searchField?.stringValue
    }
    
    /// Simulates typing in the search field (for testing)
    func simulateSearch(query: String) {
        searchField?.stringValue = query
        handleSearch(searchField!)
    }
    
    /// Returns the content view for snapshot testing
    func getContentView() -> NSView? {
        return window?.contentView
    }
    
    /// Returns the window for snapshot testing
    func getWindow() -> NSWindow? {
        return window
    }
    
    /// Sets search results directly for snapshot testing
    func setSearchResultsForTesting(_ results: [SearchResult]) {
        self.searchMode = .applications
        self.searchResults = results
        self.selectedRowIndex = results.isEmpty ? -1 : 0
        self.tableView?.reloadData()
        if !results.isEmpty {
            self.tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
    
    /// Sets clipboard results directly for snapshot testing
    func setClipboardResultsForTesting(_ items: [ClipboardItem]) {
        self.searchMode = .clipboard
        self.clipboardResults = items.map { ClipboardSearchResult(item: $0, relevanceScore: 0) }
        self.selectedRowIndex = items.isEmpty ? -1 : 0
        searchField?.placeholderString = "Search clipboard history..."
        self.tableView?.reloadData()
        if !items.isEmpty {
            self.tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
    
    /// Select a specific row for snapshot testing
    func selectRowForTesting(_ row: Int) {
        let count = searchMode == .clipboard ? clipboardResults.count : searchResults.count
        guard row >= 0 && row < count else { return }
        selectedRowIndex = row
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView?.scrollRowToVisible(row)
    }
    
    // MARK: - Accessibility Test Helpers
    
    /// Returns the search field for accessibility testing
    func getSearchField() -> NSSearchField? {
        return searchField
    }
    
    /// Returns the table view for accessibility testing
    func getTableView() -> NSTableView? {
        return tableView
    }
    
    /// Returns the cell view at a specific row for accessibility testing
    func getCellViewForTesting(at row: Int) -> NSView? {
        guard let tableView = tableView else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
    }
    
    /// Returns the selected row index for testing
    func getSelectedRowIndex() -> Int {
        return selectedRowIndex
    }
}

// MARK: - NSTableViewDataSource
extension WindowManager: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return searchMode == .clipboard ? clipboardResults.count : searchResults.count
    }
}

// MARK: - NSTableViewDelegate
extension WindowManager: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Create or reuse a text view
        let cellId = NSUserInterfaceItemIdentifier("AppCell")
        var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField

        if cell == nil {
            cell = NSTextField()
            cell?.identifier = cellId
            cell?.isBordered = false
            cell?.isEditable = false
            cell?.isSelectable = false
            cell?.backgroundColor = .clear
            cell?.font = NSFont.systemFont(ofSize: 14)
            cell?.lineBreakMode = .byTruncatingTail
        }

        // Display based on search mode
        if searchMode == .clipboard {
            guard row >= 0 && row < clipboardResults.count else {
                return nil
            }

            let item = clipboardResults[row].item
            // Truncate the content for display (max 100 chars)
            let displayContent = item.content.count > 100
                ? String(item.content.prefix(100)) + "..."
                : item.content
            cell?.stringValue = displayContent
            
            // Accessibility for clipboard row
            cell?.setAccessibilityIdentifier("ClipboardRow_\(row)")
            cell?.setAccessibilityLabel("Clipboard item: \(displayContent)")
            cell?.setAccessibilityHelp("Press Enter to copy this item to clipboard")
        } else {
            guard row >= 0 && row < searchResults.count else {
                return nil
            }

            let result = searchResults[row]
            let appInfo = result.application
            cell?.stringValue = appInfo.name
            
            // Accessibility for application row
            cell?.setAccessibilityIdentifier("ApplicationRow_\(row)")
            cell?.setAccessibilityLabel("Application: \(appInfo.name)")
            cell?.setAccessibilityHelp("Press Enter to launch this application")
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = tableView else { return }
        selectedRowIndex = tableView.selectedRow
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 36
    }
}

// NSWindowDelegate to handle window events
extension WindowManager: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Optional: hide window when losing focus
        // hide()
    }
}

// NSSearchFieldDelegate to handle arrow keys in search field
extension WindowManager: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            navigateResults(direction: -1)
            return true
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            navigateResults(direction: 1)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            handleEnterKey()
            return true
        }
        return false
    }
}
