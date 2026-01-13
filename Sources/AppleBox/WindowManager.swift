import AppKit
import CoreGraphics
import QuartzCore

// MARK: - Search Mode
enum SearchMode {
    case applications
    case clipboard
}

// Result type for clipboard search
struct ClipboardSearchResult {
    let item: ClipboardItem
    let relevanceScore: Int
    /// Character indices in item.content that matched the query.
    let matchedIndices: [Int]
}

protocol AppIconProviding {
    func icon(forBundlePath: String) -> NSImage
}

struct SystemAppIconProvider: AppIconProviding {
    func icon(forBundlePath: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: forBundlePath)
    }
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
    private var sidecarWindow: AppleBoxWindow?
    private var sidecarContentView: NSView?
    private var isWindowVisible = false
    private var isSidecarVisible = false
    private var searchField: NSSearchField?
    private var headerPanel: NSView?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?

    private var searchService: SearchService?
    private var searchResults: [SearchResult] = []
    private var selectedRowIndex: Int = -1

    // Clipboard support
    private var clipboardManager: ClipboardManager?
    private var clipboardResults: [ClipboardSearchResult] = []
    private var searchMode: SearchMode = .applications

    private var lastSearchQuery: String = ""
    private var userHasOverriddenPinnedScrollSinceLastQueryChange = false
    private var isPerformingProgrammaticScroll = false
    private var isNavigatingProgrammatically = false

    private var lastResultsAnimationUptime: TimeInterval = 0
    private var searchDebounceWorkItem: DispatchWorkItem?
    private let searchDebounceInterval: TimeInterval = 0.05  // 50ms debounce

    // Injected dependencies
    private let workspace: WorkspaceProtocol
    private let pasteboard: PasteboardProtocol
    private let eventSource: EventSourceProtocol
    private let fileSystem: FileSystemProtocol
    private let iconProvider: AppIconProviding

    init(
        workspace: WorkspaceProtocol = SystemWorkspace(),
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        eventSource: EventSourceProtocol = SystemEventSource(),
        fileSystem: FileSystemProtocol = SystemFileManager(),
        iconProvider: AppIconProviding = SystemAppIconProvider()
    ) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.eventSource = eventSource
        self.fileSystem = fileSystem
        self.iconProvider = iconProvider
        super.init()
        setupWindow()
        observeAccessibilityChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Accessibility Settings (US-005)
    
    /// Returns current accessibility settings from macOS
    private func getAccessibilitySettings() -> (reduceTransparency: Bool, increaseContrast: Bool, reduceMotion: Bool) {
        return (
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
    
    /// Observes accessibility setting changes and updates UI accordingly
    private func observeAccessibilityChanges() {
        // NSWorkspace posts notifications when accessibility settings change
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccessibilitySettings()
        }
    }
    
    /// Applies current accessibility settings to all UI elements
    private func applyAccessibilitySettings() {
        let settings = getAccessibilitySettings()
        
        // Update main window
        if let window = window, let glassView = window.contentView as? NSVisualEffectView {
            updateGlassViewForAccessibility(glassView, settings: settings)
            
            // Update overlay and panels within the glass view
            for subview in glassView.subviews {
                if subview is NSVisualEffectView {
                    continue  // Skip the glass view itself
                }
                updateOverlayForAccessibility(subview, settings: settings, isSidecar: false)
            }
        }
        
        // Update sidecar window
        if let sidecar = sidecarWindow, let glassView = sidecar.contentView as? NSVisualEffectView {
            updateGlassViewForAccessibility(glassView, settings: settings)
            
            for subview in glassView.subviews {
                updateOverlayForAccessibility(subview, settings: settings, isSidecar: true)
            }
        }
        
        // Refresh header panel styling (might need contrast adjustment)
        if let headerPanel = headerPanel {
            updatePanelForAccessibility(headerPanel, settings: settings, isSidecar: false)
        }
        
        // Reload table to update cards
        tableView?.reloadData()
    }
    
    /// Updates glass view material based on accessibility settings
    private func updateGlassViewForAccessibility(_ glassView: NSVisualEffectView, settings: (reduceTransparency: Bool, increaseContrast: Bool, reduceMotion: Bool)) {
        // When Reduce Transparency is enabled, reduce blur effect
        if settings.reduceTransparency {
            glassView.material = .sidebar  // Less translucent material
            glassView.state = .active
        } else {
            glassView.material = .hudWindow  // Original translucent material
            glassView.state = .active
        }
    }
    
    /// Updates overlay opacity based on accessibility settings
    private func updateOverlayForAccessibility(_ overlay: NSView, settings: (reduceTransparency: Bool, increaseContrast: Bool, reduceMotion: Bool), isSidecar: Bool) {
        guard let layer = overlay.layer else { return }
        
        // Base opacity values
        let baseOverlayOpacity: CGFloat = isSidecar ? 0.16 : 0.22
        let baseStrokeOpacity: CGFloat = isSidecar ? 0.2 : 0.3
        
        // Adjust for Reduce Transparency (increase opacity, less reliance on blur)
        var overlayOpacity = baseOverlayOpacity
        var strokeOpacity = baseStrokeOpacity
        
        if settings.reduceTransparency {
            overlayOpacity = min(overlayOpacity + 0.2, 0.7)  // Significantly increase opacity
        }
        
        // Adjust for Increase Contrast (strengthen strokes)
        if settings.increaseContrast {
            strokeOpacity = min(strokeOpacity + 0.25, 0.8)  // Strengthen strokes
        }
        
        // Apply settings
        if let bgColor = layer.backgroundColor {
            let color = NSColor(cgColor: bgColor)?.withAlphaComponent(overlayOpacity)
            layer.backgroundColor = color?.cgColor
        }
        
        if let borderColor = layer.borderColor {
            let color = NSColor(cgColor: borderColor)?.withAlphaComponent(strokeOpacity)
            layer.borderColor = color?.cgColor
            
            // Increase border width for better visibility in high contrast
            if settings.increaseContrast {
                layer.borderWidth = 1.0  // Thicker stroke
            }
        }
    }
    
    /// Updates panel styling based on accessibility settings
    private func updatePanelForAccessibility(_ panel: NSView, settings: (reduceTransparency: Bool, increaseContrast: Bool, reduceMotion: Bool), isSidecar: Bool) {
        guard let layer = panel.layer else { return }
        
        // Base values for main vs sidecar
        let basePanelOpacity: CGFloat = isSidecar ? 0.09 : 0.12
        let basePanelStroke: CGFloat = isSidecar ? 0.18 : 0.25
        
        var panelOpacity = basePanelOpacity
        var strokeOpacity = basePanelStroke
        
        // Adjust for Reduce Transparency
        if settings.reduceTransparency {
            panelOpacity = min(panelOpacity + 0.15, 0.5)
        }
        
        // Adjust for Increase Contrast
        if settings.increaseContrast {
            strokeOpacity = min(strokeOpacity + 0.25, 0.7)
        }
        
        // Apply background color
        layer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(panelOpacity).cgColor
        
        // Apply border color
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(strokeOpacity).cgColor
        
        // Increase border width for high contrast
        if settings.increaseContrast {
            layer.borderWidth = 1.0
        } else {
            layer.borderWidth = 0.5
        }
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

        // Liquid-glass window
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true

        // Accessibility for window
        window.setAccessibilityIdentifier("AppleBoxWindow")
        window.setAccessibilityLabel("AppleBox Launcher")
        window.setAccessibilityHelp("Quick launcher for applications and clipboard history")

        // Handle key events
        window.escapeHandler = { [weak self] in
            self?.hide()
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

        // Glass background container with premium panel styling
        let glassView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        glassView.autoresizingMask = [.width, .height]
        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 20  // Premium corner radius
        glassView.layer?.masksToBounds = true
        if #available(macOS 11.0, *) {
            glassView.layer?.cornerCurve = .continuous
        }

        // Subtle readability overlay (keeps text crisp on blur)
        let overlayView = NSView(frame: glassView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.22).cgColor
        
        // Subtle premium stroke
        overlayView.layer?.borderWidth = 0.5
        overlayView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        overlayView.layer?.cornerRadius = 20
        overlayView.layer?.masksToBounds = true

        // Content view (controls live here)
        let contentView = NSView(frame: glassView.bounds)
        contentView.autoresizingMask = [.width, .height]

        glassView.addSubview(overlayView)
        glassView.addSubview(contentView)
        window.contentView = glassView

        // Premium header panel for search field
        let headerPanel = NSView(frame: NSRect(x: 16, y: 340, width: 568, height: 48))
        headerPanel.wantsLayer = true
        headerPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.15).cgColor
        headerPanel.layer?.cornerRadius = 18
        headerPanel.layer?.borderWidth = 0.5
        headerPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        if #available(macOS 11.0, *) {
            headerPanel.layer?.cornerCurve = .continuous
        }
        contentView.addSubview(headerPanel)
        self.headerPanel = headerPanel
        
        // Create search field inside header panel
        // Text draws at top of field, so use smaller height and position to center visually
        let searchField = NSSearchField(frame: NSRect(x: 16, y: 12, width: 536, height: 24))
        searchField.placeholderString = "Search applications..."
        searchField.font = NSFont.systemFont(ofSize: 17)
        searchField.target = self
        searchField.action = #selector(handleSearch(_:))
        searchField.delegate = self
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.backgroundColor = .clear
        searchField.textColor = .labelColor
        
        // Hide search/cancel icons for cleaner look
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }

        // Accessibility for search field
        searchField.setAccessibilityIdentifier("AppleBoxSearchField")
        searchField.setAccessibilityLabel("Search Field")
        searchField.setAccessibilityHelp("Type to search for applications (Cmd+Space). Search clipboard history with Opt+Space.")

        headerPanel.addSubview(searchField)
        self.searchField = searchField
        
        // Set up focus observation for custom focus styling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchFieldDidBeginEditing(_:)),
            name: NSControl.textDidBeginEditingNotification,
            object: searchField
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchFieldDidEndEditing(_:)),
            name: NSControl.textDidEndEditingNotification,
            object: searchField
        )

        // Premium results panel - matching glass style of search view with translucent blend
        let resultsPanel = NSView(frame: NSRect(x: 16, y: 16, width: 568, height: 316))
        resultsPanel.wantsLayer = true
        // Fully transparent background - let glass blur show through
        resultsPanel.layer?.backgroundColor = NSColor.clear.cgColor
        resultsPanel.layer?.cornerRadius = 18
        resultsPanel.layer?.borderWidth = 0.5
        resultsPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor  // Lighter stroke
        if #available(macOS 11.0, *) {
            resultsPanel.layer?.cornerCurve = .continuous
        }
        contentView.addSubview(resultsPanel)
        
        // Create scroll view for results inside panel
        let scrollView = NSScrollView(frame: NSRect(x: 12, y: 12, width: 544, height: 292))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false  // Prevent dark background drawing
        scrollView.contentView.drawsBackground = false  // Clip view also needs this

        // Track user scrolling so we don't fight it
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resultsDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Create table view
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.style = .plain
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 6)  // Spacing between card rows
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none  // Custom selection drawing
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true

        // Accessibility for table view
        tableView.setAccessibilityIdentifier("AppleBoxResultsTable")
        tableView.setAccessibilityLabel("Search Results")
        tableView.setAccessibilityHelp("Use arrow keys to navigate results, Enter to select.")

        // Create single text column - match scrollView width for proper alignment
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.width = 544  // Match scrollView width to prevent right-side overflow
        column.dataCell = NSTextFieldCell()
        tableView.addTableColumn(column)

        // Set up data source and delegate
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))

        scrollView.documentView = tableView
        resultsPanel.addSubview(scrollView)

        self.tableView = tableView
        self.scrollView = scrollView

        // Set window delegate
        window.delegate = self
        window.initialFirstResponder = searchField

        self.window = window
        setupSidecarWindow()
        
        // Apply accessibility settings to initial UI
        applyAccessibilitySettings()
    }

    private func setupSidecarWindow() {
        let sidecarWidth: CGFloat = 320
        let sidecarHeight: CGFloat = 400  // Match main window height

        let sidecarWindow = AppleBoxWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidecarWidth, height: sidecarHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Glass styling matching main window
        sidecarWindow.backgroundColor = .clear
        sidecarWindow.isOpaque = false
        sidecarWindow.hasShadow = true
        sidecarWindow.level = .floating
        sidecarWindow.isMovableByWindowBackground = false

        // Accessibility
        sidecarWindow.setAccessibilityIdentifier("AppleBoxSidecarWindow")
        sidecarWindow.setAccessibilityLabel("Clipboard Preview Panel")
        sidecarWindow.setAccessibilityHelp("Preview panel for clipboard items")

        // Sidecar escape also hides main window
        sidecarWindow.escapeHandler = { [weak self] in
            self?.hide()
        }

        // Glass background container with premium panel styling
        let glassView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidecarWidth, height: sidecarHeight))
        glassView.autoresizingMask = [.width, .height]
        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 20  // Premium corner radius
        glassView.layer?.masksToBounds = true
        if #available(macOS 11.0, *) {
            glassView.layer?.cornerCurve = .continuous
        }

        // Subtle readability overlay with premium stroke (LOWER CONTRAST for sidecar)
        // Reduced opacity for a more receded, blended appearance
        let overlayView = NSView(frame: glassView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.16).cgColor  // Reduced from 0.22
        overlayView.layer?.borderWidth = 0.5
        overlayView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor  // Reduced from 0.3
        overlayView.layer?.cornerRadius = 20
        overlayView.layer?.masksToBounds = true

        // Container for sidecar content
        let containerView = NSView(frame: glassView.bounds)
        containerView.autoresizingMask = [.width, .height]
        
        // Premium content panel (LOWER CONTRAST for sidecar)
        // Slightly reduced background for a softer, more receded appearance
        let contentPanel = NSView(frame: NSRect(x: 16, y: 16, width: sidecarWidth - 32, height: sidecarHeight - 32))
        contentPanel.autoresizingMask = [.width, .height]
        contentPanel.wantsLayer = true
        contentPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.09).cgColor  // Reduced from 0.12
        contentPanel.layer?.cornerRadius = 18
        contentPanel.layer?.borderWidth = 0.5
        contentPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor  // Reduced from 0.25
        if #available(macOS 11.0, *) {
            contentPanel.layer?.cornerCurve = .continuous
        }

        containerView.addSubview(contentPanel)
        glassView.addSubview(overlayView)
        glassView.addSubview(containerView)
        sidecarWindow.contentView = glassView

        self.sidecarWindow = sidecarWindow
        self.sidecarContentView = contentPanel
    }

    // MARK: - Sidecar Panel Methods

    /// Shows the sidecar panel positioned to the right of the main window.
    func showSidecar() {
        guard let mainWindow = window, let sidecar = sidecarWindow else { return }
        guard searchMode == .clipboard else { return }  // Only show in clipboard mode

        let gap: CGFloat = 8
        let mainFrame = mainWindow.frame
        let sidecarOrigin = NSPoint(
            x: mainFrame.maxX + gap,
            y: mainFrame.origin.y
        )

        sidecar.setFrameOrigin(sidecarOrigin)
        sidecar.makeKeyAndOrderFront(nil)

        // Ensure main window stays key
        mainWindow.makeKeyAndOrderFront(nil)

        isSidecarVisible = true
        print("Sidecar shown")
    }

    /// Hides the sidecar panel.
    func hideSidecar() {
        sidecarWindow?.orderOut(nil)
        clearSidecarContent()
        isSidecarVisible = false
        print("Sidecar hidden")
    }

    /// Returns whether the sidecar is currently visible.
    func isSidecarShowing() -> Bool {
        return isSidecarVisible
    }

    // MARK: - Sidecar Visibility Rules (US-006)

    /// Estimates the visible character count for a single-line row.
    /// Row width ~560px with 14pt system font ≈ ~50 characters visible.
    private let singleLineCharacterLimit = 50

    /// Updates sidecar visibility based on the selected clipboard item.
    /// - Shows sidecar for images
    /// - Shows sidecar when text overflows single-line row
    /// - Hides sidecar otherwise
    private func updateSidecarVisibility() {
        guard searchMode == .clipboard else {
            hideSidecar()
            return
        }

        guard selectedRowIndex >= 0 && selectedRowIndex < clipboardResults.count else {
            hideSidecar()
            return
        }

        let item = clipboardResults[selectedRowIndex].item

        // Rule 1: Show for images
        if item.contentType == .image {
            updateSidecarContent(for: item)
            showSidecar()
            return
        }

        // Rule 2: Show for overflowing text
        if item.content.count > singleLineCharacterLimit || item.content.contains("\n") {
            updateSidecarContent(for: item)
            showSidecar()
            return
        }

        // Rule 3: Hide otherwise
        hideSidecar()
    }

    /// Updates the sidecar content view with the appropriate preview.
    private func updateSidecarContent(for item: ClipboardItem) {
        clearSidecarContent()

        guard let contentView = sidecarContentView else { return }

        if item.contentType == .image, let image = item.getImage() {
            // Image preview
            let imageView = NSImageView(frame: contentView.bounds.insetBy(dx: 16, dy: 16))
            imageView.autoresizingMask = [.width, .height]
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = image
            imageView.setAccessibilityIdentifier("SidecarImagePreview")
            imageView.setAccessibilityLabel("Clipboard image preview")
            contentView.addSubview(imageView)
        } else {
            // Text preview with smart formatting
            let scrollView = NSScrollView(frame: contentView.bounds.insetBy(dx: 16, dy: 16))
            scrollView.autoresizingMask = [.width, .height]
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = .clear
            scrollView.drawsBackground = false

            let textView = NSTextView(frame: scrollView.bounds)
            textView.autoresizingMask = [.width]
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 4, height: 4)

            // Smart formatting: monospace for code-like content
            let font = isCodeLike(item.content)
                ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                : NSFont.systemFont(ofSize: 13)

            textView.font = font
            textView.textColor = .labelColor
            textView.string = item.content

            scrollView.documentView = textView
            scrollView.setAccessibilityIdentifier("SidecarTextPreview")
            scrollView.setAccessibilityLabel("Clipboard text preview")
            contentView.addSubview(scrollView)
        }
    }

    /// Clears all subviews from the sidecar content view.
    private func clearSidecarContent() {
        sidecarContentView?.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Heuristic to detect code-like content for monospace formatting.
    /// Detects: common code patterns, indentation, brackets, semicolons, etc.
    private func isCodeLike(_ text: String) -> Bool {
        // Code indicators
        let codePatterns = [
            "func ", "class ", "struct ", "enum ", "let ", "var ", "import ",  // Swift
            "function ", "const ", "=>", "===", "!==",  // JavaScript
            "def ", "if __name__", "import ", "from ",  // Python
            "{", "}", "[", "]", "();", "();", "->", "::",  // Common syntax
        ]

        let lowercased = text.lowercased()

        // Check for code patterns
        for pattern in codePatterns {
            if lowercased.contains(pattern.lowercased()) {
                return true
            }
        }

        // Check for indentation (multiple leading spaces/tabs on lines)
        let lines = text.components(separatedBy: "\n")
        let indentedLines = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        if indentedLines.count > 2 {
            return true
        }

        return false
    }

    func toggle(mode: SearchMode? = nil) {
        if isWindowVisible {
            // If window is visible, switch to the requested mode or hide
            if let mode = mode, mode != searchMode {
                switchToMode(mode)
            } else {
                hide()
            }
        } else {
            show(mode: mode)
        }
    }

    @objc private func resultsDidScroll(_ notification: Notification) {
        guard !isPerformingProgrammaticScroll else { return }
        userHasOverriddenPinnedScrollSinceLastQueryChange = true
    }

    private func scrollResultsToTop(selectFirstRow: Bool) {
        guard let scrollView = scrollView else { return }

        isPerformingProgrammaticScroll = true
        defer { isPerformingProgrammaticScroll = false }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        guard selectFirstRow, let tableView = tableView else { return }

        let count = searchMode == .clipboard ? clipboardResults.count : searchResults.count
        if count > 0 {
            selectedRowIndex = 0
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        } else {
            selectedRowIndex = -1
            tableView.deselectAll(nil)
        }
    }

    private func reloadResults(animate: Bool) {
        tableView?.reloadData()
        if animate {
            animateResultsUpdateIfAppropriate()
        }
    }

    private func animateResultsUpdateIfAppropriate() {
        guard isWindowVisible, let scrollView = scrollView else { return }
        let settings = getAccessibilitySettings()
        guard !settings.reduceMotion else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let minimumInterval: TimeInterval = 0.10
        if now - lastResultsAnimationUptime < minimumInterval { return }
        lastResultsAnimationUptime = now

        let baseFrame = scrollView.frame
        let offset: CGFloat = 6

        scrollView.wantsLayer = true
        scrollView.alphaValue = 0.92
        scrollView.setFrameOrigin(NSPoint(x: baseFrame.origin.x, y: baseFrame.origin.y - offset))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.animator().alphaValue = 1.0
            scrollView.animator().setFrameOrigin(baseFrame.origin)
        }
    }

    private func switchToMode(_ mode: SearchMode) {
        searchMode = mode

        if let searchField = searchField {
            if mode == .clipboard {
                searchField.stringValue = ""  // Don't show ">" in clipboard mode
                searchField.placeholderString = "Search clipboard history..."
                // Load clipboard history
                if let manager = clipboardManager {
                    let history = manager.getHistory()
                    clipboardResults = history.map { ClipboardSearchResult(item: $0, relevanceScore: 0, matchedIndices: []) }
                }
                selectedRowIndex = clipboardResults.isEmpty ? -1 : 0
            } else {
                searchField.stringValue = ""
                searchField.placeholderString = "Search applications..."
                searchResults = []
                clipboardResults = []
                selectedRowIndex = -1
            }
            window?.makeFirstResponder(searchField)
        }

        tableView?.reloadData()

        lastSearchQuery = searchField?.stringValue ?? ""
        userHasOverriddenPinnedScrollSinceLastQueryChange = false
        scrollResultsToTop(selectFirstRow: true)
        updateSidecarVisibility()

        print("Switched to \(mode) mode")
    }

    func show(mode: SearchMode? = nil) {
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

        // Set search mode
        if let mode = mode {
            searchMode = mode
        } else {
            searchMode = .applications
        }

        // Configure based on mode
        if let searchField = searchField {
            if searchMode == .clipboard {
                searchField.stringValue = ""  // Don't show ">" in clipboard mode
                searchField.placeholderString = "Search clipboard history..."
                // Load clipboard history
                if let manager = clipboardManager {
                    let history = manager.getHistory()
                    clipboardResults = history.map { ClipboardSearchResult(item: $0, relevanceScore: 0, matchedIndices: []) }
                }
                selectedRowIndex = clipboardResults.isEmpty ? -1 : 0
            } else {
                searchField.stringValue = ""
                searchField.placeholderString = "Search applications..."
                searchResults = []
                clipboardResults = []
                selectedRowIndex = -1
            }
            window.makeFirstResponder(searchField)
        }

        tableView?.reloadData()

        lastSearchQuery = searchField?.stringValue ?? ""
        userHasOverriddenPinnedScrollSinceLastQueryChange = false
        scrollResultsToTop(selectFirstRow: true)
        updateSidecarVisibility()

        isWindowVisible = true
        print("Window shown in \(searchMode) mode")
    }

    func hide() {
        hideSidecar()
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

        if query != lastSearchQuery {
            userHasOverriddenPinnedScrollSinceLastQueryChange = false
            lastSearchQuery = query
        }

        // Cancel any pending debounced search
        searchDebounceWorkItem?.cancel()

        // Debounce search to avoid per-keystroke overhead
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSearch(query: query)
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceInterval, execute: workItem)
    }
    
    // MARK: - Focus Treatment (US-002)
    
    @objc private func searchFieldDidBeginEditing(_ notification: Notification) {
        updateSearchFieldFocusState(focused: true)
    }
    
    @objc private func searchFieldDidEndEditing(_ notification: Notification) {
        updateSearchFieldFocusState(focused: false)
    }
    
    /// Updates the header panel styling to show premium focus treatment.
    /// - Adds subtle inner glow and thin accent stroke when focused
    /// - Respects Reduce Motion for animations and Increase Contrast for visibility
    private func updateSearchFieldFocusState(focused: Bool) {
        guard let headerPanel = headerPanel else { return }
        guard let layer = headerPanel.layer else { return }
        
        let settings = getAccessibilitySettings()
        let shouldAnimate = !settings.reduceMotion
        
        if focused {
            // Premium focus: thin accent stroke + subtle inner glow
            // Adjust opacity for Increase Contrast
            let accentAlpha: CGFloat = settings.increaseContrast ? 0.75 : 0.5
            let glowAlpha: CGFloat = settings.increaseContrast ? 0.25 : 0.15
            let borderWidth: CGFloat = settings.increaseContrast ? 2.0 : 1.5
            
            let accentColor = NSColor.controlAccentColor.withAlphaComponent(accentAlpha)
            let glowColor = NSColor.controlAccentColor.withAlphaComponent(glowAlpha)
            
            if shouldAnimate {
                // Smooth transition
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.borderColor = accentColor.cgColor
                    layer.borderWidth = borderWidth
                    layer.backgroundColor = glowColor.cgColor
                }
            } else {
                // Instant change
                layer.borderColor = accentColor.cgColor
                layer.borderWidth = borderWidth
                layer.backgroundColor = glowColor.cgColor
            }
        } else {
            // Return to default panel styling
            // Adjust for Increase Contrast
            let strokeAlpha: CGFloat = settings.increaseContrast ? 0.5 : 0.25
            let bgAlpha: CGFloat = settings.increaseContrast ? 0.25 : 0.15
            let borderWidth: CGFloat = settings.increaseContrast ? 1.0 : 0.5
            
            let defaultStroke = NSColor.separatorColor.withAlphaComponent(strokeAlpha).cgColor
            let defaultBackground = NSColor.controlBackgroundColor.withAlphaComponent(bgAlpha).cgColor
            
            if shouldAnimate {
                // Smooth transition
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.borderColor = defaultStroke
                    layer.borderWidth = borderWidth
                    layer.backgroundColor = defaultBackground
                }
            } else {
                // Instant change
                layer.borderColor = defaultStroke
                layer.borderWidth = borderWidth
                layer.backgroundColor = defaultBackground
            }
        }
    }

    /// Performs the actual search (called after debounce).
    private func performSearch(query: String) {
        if searchMode == .clipboard {
            searchResults = []

            guard let manager = clipboardManager else {
                clipboardResults = []
                selectedRowIndex = -1
                reloadResults(animate: true)
                if !userHasOverriddenPinnedScrollSinceLastQueryChange {
                    scrollResultsToTop(selectFirstRow: true)
                }
                return
            }

            // Use searchHistoryWithMatches to avoid duplicate fuzzy matching
            let matches = manager.searchHistoryWithMatches(query: query)
            clipboardResults = matches.map { match in
                ClipboardSearchResult(item: match.item, relevanceScore: match.score, matchedIndices: match.matchedIndices)
            }

            selectedRowIndex = clipboardResults.isEmpty ? -1 : 0
        } else {
            clipboardResults = []

            guard let searchService = searchService else { return }

            if query.isEmpty {
                searchResults = []
                selectedRowIndex = -1
            } else {
                searchResults = searchService.search(query)
                selectedRowIndex = searchResults.isEmpty ? -1 : 0
            }
        }

        reloadResults(animate: true)

        if !userHasOverriddenPinnedScrollSinceLastQueryChange {
            scrollResultsToTop(selectFirstRow: true)
        }
        updateSidecarVisibility()
    }

    private func navigateResults(direction: Int) {
        userHasOverriddenPinnedScrollSinceLastQueryChange = true
        // Determine which result set to use based on mode
        let resultCount = searchMode == .clipboard ? clipboardResults.count : searchResults.count
        guard resultCount > 0 else { return }

        let newIndex = selectedRowIndex + direction

        // Handle navigation boundaries without wrapping
        if newIndex < 0 {
            // Going up from first element (or no selection) - focus search field
            let previousIndex = selectedRowIndex
            selectedRowIndex = -1
            tableView?.deselectAll(nil)
            // Deselect the previous card visually
            if let tableView = tableView {
                updateCardSelectionVisuals(tableView: tableView, previousRow: previousIndex, currentRow: -1)
            }
            window?.makeFirstResponder(searchField)
            print("Focus returned to search field")
            return
        } else if newIndex >= resultCount {
            // At last element, don't wrap - stay at last
            return
        }

        // Save previous index BEFORE updating for correct visual update
        let previousIndex = selectedRowIndex
        selectedRowIndex = newIndex
        
        // Prevent tableViewSelectionDidChange from double-updating visuals
        isNavigatingProgrammatically = true
        tableView?.selectRowIndexes(IndexSet(integer: selectedRowIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(selectedRowIndex)
        isNavigatingProgrammatically = false
        
        // Manually update card visuals with correct previous/current indices
        if let tableView = tableView {
            updateCardSelectionVisuals(tableView: tableView, previousRow: previousIndex, currentRow: selectedRowIndex)
        }
        updateSidecarVisibility()

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
    
    /// Simulates typing in the search field (for testing).
    /// Executes search synchronously (bypassing debounce) for test reliability.
    func simulateSearch(query: String) {
        searchField?.stringValue = query
        // Cancel any pending debounced search
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil
        // Update query tracking
        if query != lastSearchQuery {
            userHasOverriddenPinnedScrollSinceLastQueryChange = false
            lastSearchQuery = query
        }
        // Execute search synchronously for tests
        performSearch(query: query)
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
        self.clipboardResults = items.map { ClipboardSearchResult(item: $0, relevanceScore: 0, matchedIndices: []) }
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
    
    // MARK: - Sidecar Test Helpers
    
    /// Returns the sidecar window for testing
    func getSidecarWindow() -> NSWindow? {
        return sidecarWindow
    }
    
    /// Returns the sidecar content view for testing
    func getSidecarContentView() -> NSView? {
        return sidecarContentView
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
        // Display based on search mode
        if searchMode == .clipboard {
            return makeClipboardCell(tableView: tableView, row: row)
        } else {
            return makeApplicationCell(tableView: tableView, row: row)
        }
    }
    
    private func makeClipboardCell(tableView: NSTableView, row: Int) -> NSView? {
        guard row >= 0 && row < clipboardResults.count else { return nil }
        
        let cellId = NSUserInterfaceItemIdentifier("ClipboardCell")
        var cardContainer = tableView.makeView(withIdentifier: cellId, owner: nil)
        
        if cardContainer == nil {
            let settings = getAccessibilitySettings()
            
            // Create card container with premium styling
            cardContainer = NSView()
            cardContainer?.identifier = cellId
            cardContainer?.wantsLayer = true
            
            // Card background and stroke (adjusted for accessibility)
            let bgAlpha: CGFloat = settings.increaseContrast ? 0.15 : 0.08
            let strokeAlpha: CGFloat = settings.increaseContrast ? 0.5 : 0.2
            let strokeWidth: CGFloat = settings.increaseContrast ? 0.75 : 0.5
            
            cardContainer?.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(bgAlpha).cgColor
            cardContainer?.layer?.cornerRadius = 12
            cardContainer?.layer?.borderWidth = strokeWidth
            cardContainer?.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(strokeAlpha).cgColor
            if #available(macOS 11.0, *) {
                cardContainer?.layer?.cornerCurve = .continuous
            }
            
            // Text field inside card
            let textField = NSTextField()
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.backgroundColor = .clear
            textField.font = NSFont.systemFont(ofSize: 14)
            textField.lineBreakMode = .byTruncatingTail
            textField.tag = 200
            cardContainer?.addSubview(textField)
            
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cardContainer!.leadingAnchor, constant: 16),
                textField.trailingAnchor.constraint(equalTo: cardContainer!.trailingAnchor, constant: -16),
                textField.centerYAnchor.constraint(equalTo: cardContainer!.centerYAnchor)
            ])
        }
        
        let result = clipboardResults[row]
        let item = result.item
        let displayContent = item.content.count > 100
            ? String(item.content.prefix(100)) + "..."
            : item.content
        
        // Apply highlighting to matched indices (adjust for truncation)
        let truncatedIndices = result.matchedIndices.filter { $0 < displayContent.count }
        
        if let textField = cardContainer?.viewWithTag(200) as? NSTextField {
            textField.attributedStringValue = attributedString(
                for: displayContent,
                highlightingIndices: truncatedIndices,
                font: textField.font ?? NSFont.systemFont(ofSize: 14)
            )
        }
        
        // Apply initial selection styling
        let isSelected = (selectedRowIndex == row)
        applyCardSelectionStyle(to: cardContainer, isSelected: isSelected, animated: false)
        
        // Accessibility
        cardContainer?.setAccessibilityIdentifier("ClipboardRow_\(row)")
        cardContainer?.setAccessibilityLabel("Clipboard item: \(displayContent)")
        cardContainer?.setAccessibilityHelp("Press Enter to copy this item to clipboard")
        
        return cardContainer
    }
    
    private func makeApplicationCell(tableView: NSTableView, row: Int) -> NSView? {
        guard row >= 0 && row < searchResults.count else { return nil }
        
        let cellId = NSUserInterfaceItemIdentifier("AppCell")
        var cardContainer = tableView.makeView(withIdentifier: cellId, owner: nil)
        
        let iconSize: CGFloat = 24
        let padding: CGFloat = 16
        
        if cardContainer == nil {
            let settings = getAccessibilitySettings()
            
            // Create card container with premium styling
            cardContainer = NSView()
            cardContainer?.identifier = cellId
            cardContainer?.wantsLayer = true
            
            // Card background and stroke (adjusted for accessibility)
            let bgAlpha: CGFloat = settings.increaseContrast ? 0.15 : 0.08
            let strokeAlpha: CGFloat = settings.increaseContrast ? 0.5 : 0.2
            let strokeWidth: CGFloat = settings.increaseContrast ? 0.75 : 0.5
            
            cardContainer?.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(bgAlpha).cgColor
            cardContainer?.layer?.cornerRadius = 12
            cardContainer?.layer?.borderWidth = strokeWidth
            cardContainer?.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(strokeAlpha).cgColor
            if #available(macOS 11.0, *) {
                cardContainer?.layer?.cornerCurve = .continuous
            }
            
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.tag = 100
            cardContainer?.addSubview(imageView)
            
            let textField = NSTextField()
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.backgroundColor = .clear
            textField.font = NSFont.systemFont(ofSize: 14)
            textField.lineBreakMode = .byTruncatingTail
            textField.tag = 101
            cardContainer?.addSubview(textField)
            
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cardContainer!.leadingAnchor, constant: padding),
                imageView.centerYAnchor.constraint(equalTo: cardContainer!.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: iconSize),
                imageView.heightAnchor.constraint(equalToConstant: iconSize),
                
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
                textField.trailingAnchor.constraint(equalTo: cardContainer!.trailingAnchor, constant: -padding),
                textField.centerYAnchor.constraint(equalTo: cardContainer!.centerYAnchor)
            ])
        }
        
        let result = searchResults[row]
        let appInfo = result.application
        
        // Get app icon
        if let imageView = cardContainer?.viewWithTag(100) as? NSImageView {
            let icon = iconProvider.icon(forBundlePath: appInfo.bundlePath)
            icon.size = NSSize(width: iconSize, height: iconSize)
            imageView.image = icon
        }
        
        // Set app name with highlighted matches
        if let textField = cardContainer?.viewWithTag(101) as? NSTextField {
            textField.attributedStringValue = attributedString(
                for: appInfo.name,
                highlightingIndices: result.matchedIndices,
                font: textField.font ?? NSFont.systemFont(ofSize: 14)
            )
        }
        
        // Apply initial selection styling
        let isSelected = (selectedRowIndex == row)
        applyCardSelectionStyle(to: cardContainer, isSelected: isSelected, animated: false)
        
        // Accessibility
        cardContainer?.setAccessibilityIdentifier("ApplicationRow_\(row)")
        cardContainer?.setAccessibilityLabel("Application: \(appInfo.name)")
        cardContainer?.setAccessibilityHelp("Press Enter to launch this application")
        
        return cardContainer
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = tableView else { return }
        
        // Skip if navigating programmatically (handled in navigateResults)
        guard !isNavigatingProgrammatically else { return }
        
        let previousSelection = selectedRowIndex
        selectedRowIndex = tableView.selectedRow
        
        // Update card styling for previous and new selection
        updateCardSelectionVisuals(tableView: tableView, previousRow: previousSelection, currentRow: selectedRowIndex)
        
        updateSidecarVisibility()
    }
    
    // MARK: - Card Selection Styling (US-003)
    
    /// Updates card selection visuals when selection changes.
    /// Applies premium outline + fill to selected card with subtle animation.
    private func updateCardSelectionVisuals(tableView: NSTableView, previousRow: Int, currentRow: Int) {
        // Deselect previous card
        if previousRow >= 0, let previousCard = tableView.view(atColumn: 0, row: previousRow, makeIfNecessary: false) {
            applyCardSelectionStyle(to: previousCard, isSelected: false, animated: true)
        }
        
        // Select new card
        if currentRow >= 0, let currentCard = tableView.view(atColumn: 0, row: currentRow, makeIfNecessary: false) {
            applyCardSelectionStyle(to: currentCard, isSelected: true, animated: true)
        }
    }
    
    /// Applies premium selection styling to a card view.
    /// - Parameters:
    ///   - card: The card container view
    ///   - isSelected: Whether the card is selected
    ///   - animated: Whether to animate the transition (respects Reduce Motion)
    private func applyCardSelectionStyle(to card: NSView?, isSelected: Bool, animated: Bool) {
        guard let card = card, let layer = card.layer else { return }
        
        let settings = getAccessibilitySettings()
        let shouldAnimate = animated && !settings.reduceMotion
        
        if isSelected {
            // Premium selection: thin accent outline + slight fill
            // Adjust opacity for Increase Contrast
            let strokeAlpha: CGFloat = settings.increaseContrast ? 0.85 : 0.6
            let fillAlpha: CGFloat = settings.increaseContrast ? 0.22 : 0.12
            
            let accentStroke = NSColor.controlAccentColor.withAlphaComponent(strokeAlpha).cgColor
            let accentFill = NSColor.controlAccentColor.withAlphaComponent(fillAlpha).cgColor
            
            // Thicker border for Increase Contrast
            let borderWidth: CGFloat = settings.increaseContrast ? 2.0 : 1.5
            
            if shouldAnimate {
                // Subtle animated transition
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.borderColor = accentStroke
                    layer.borderWidth = borderWidth
                    layer.backgroundColor = accentFill
                    layer.opacity = 1.0
                }
                
                // Very subtle pulse effect (low CPU cost) - only if motion allowed
                let pulseAnimation = CABasicAnimation(keyPath: "opacity")
                pulseAnimation.fromValue = 0.92
                pulseAnimation.toValue = 1.0
                pulseAnimation.duration = 0.25
                pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulseAnimation.autoreverses = false
                layer.add(pulseAnimation, forKey: "selectionPulse")
            } else {
                // Instant change
                layer.borderColor = accentStroke
                layer.borderWidth = borderWidth
                layer.backgroundColor = accentFill
            }
        } else {
            // Default card state
            // Adjust opacity for Increase Contrast
            let strokeAlpha: CGFloat = settings.increaseContrast ? 0.5 : 0.2
            let bgAlpha: CGFloat = settings.increaseContrast ? 0.15 : 0.08
            
            let defaultStroke = NSColor.separatorColor.withAlphaComponent(strokeAlpha).cgColor
            let defaultBackground = NSColor.controlBackgroundColor.withAlphaComponent(bgAlpha).cgColor
            
            // Thicker border for Increase Contrast
            let borderWidth: CGFloat = settings.increaseContrast ? 0.75 : 0.5
            
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.borderColor = defaultStroke
                    layer.borderWidth = borderWidth
                    layer.backgroundColor = defaultBackground
                    layer.opacity = 1.0
                }
            } else {
                // Instant change
                layer.borderColor = defaultStroke
                layer.borderWidth = borderWidth
                layer.backgroundColor = defaultBackground
            }
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 44  // Increased height for premium card feel
    }
    
    // MARK: - Attributed String Highlighting
    
    /// Creates an attributed string with matched characters highlighted using the system accent color.
    private func attributedString(for text: String, highlightingIndices indices: [Int], font: NSFont) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        
        guard !indices.isEmpty else { return attributedString }
        
        // Use controlAccentColor for highlighted matches
        let highlightColor = NSColor.controlAccentColor
        
        // Convert character indices to UTF-16 ranges for NSAttributedString
        for charIndex in indices {
            guard charIndex < text.count else { continue }
            
            let stringIndex = text.index(text.startIndex, offsetBy: charIndex)
            let utf16Offset = text.utf16.distance(from: text.utf16.startIndex, to: stringIndex)
            
            // Highlight a single character
            let range = NSRange(location: utf16Offset, length: 1)
            guard range.location + range.length <= attributedString.length else { continue }
            
            attributedString.addAttribute(.foregroundColor, value: highlightColor, range: range)
        }
        
        return attributedString
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
