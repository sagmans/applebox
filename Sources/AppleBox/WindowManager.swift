import AppKit
import CoreGraphics
import CryptoKit
import OSLog
import QuartzCore

/// Result type for clipboard search
nonisolated struct ClipboardSearchResult: Sendable {
    let item: ClipboardItem
    let relevanceScore: Int
    /// Character indices in item.content that matched the query.
    let matchedIndices: [Int]
}

private enum CopyClipShortcut {
    static let key = "\r"
    static let modifiers: NSEvent.ModifierFlags = .option
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
}

/// Custom NSWindow that handles key events
class AppleBoxWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    var arrowUpHandler: (() -> Void)?
    var arrowDownHandler: (() -> Void)?
    var enterHandler: (() -> Void)?
    var copyClipHandler: (() -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        // Reserve the shortcut before the search field interprets it as a text command.
        if event.type == .keyDown,
           event.charactersIgnoringModifiers == CopyClipShortcut.key,
           event.modifierFlags.intersection(CopyClipShortcut.relevantModifiers) == CopyClipShortcut.modifiers,
           (firstResponder as? NSTextView)?.hasMarkedText() != true,
           copyClipHandler?() == true
        {
            return
        }
        super.sendEvent(event)
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

    override func cancelOperation(_: Any?) {
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
    private var emptyResultsLabel: NSTextField?
    private let clipboardMenu = NSMenu()
    private var captureButton: NSButton?
    private var fullSearchFieldWidth: CGFloat?
    private let captureButtonSpacing: CGFloat = 12
    private var statusLabel: NSTextField?
    private let statusLabelHeight: CGFloat = 16
    private let applicationLocationSeparator = "   ·   "

    /// All launcher state lives here; this class only draws it and turns AppKit events into intents.
    private let model: LauncherModel

    private var userHasOverriddenPinnedScrollSinceLastQueryChange = false
    private var isPerformingProgrammaticScroll = false
    private var isNavigatingProgrammatically = false

    /// Set while the shell resets the model itself, because it then draws the result explicitly in
    /// the right order against the window and must not also react to the model's announcement.
    private var isSuppressingModelChanges = false
    /// Remembered so a newly arrived launch failure can pull focus back to the query exactly once.
    private var lastShownStatus: LauncherStatus?

    private var lastResultsAnimationUptime: TimeInterval = 0

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox",
        category: "window"
    )

    private let clipboardImageCache = ClipboardImageCache()

    // Sidecar text preview state (for scroll-preserving highlight updates)
    private weak var sidecarTextView: NSTextView?
    private weak var sidecarTextScrollView: NSScrollView?
    private var sidecarDisplayedItemID: UUID?
    private var sidecarHighlightedIndices: [Int] = []

    // Injected dependencies
    private let iconProvider: AppIconProviding
    private let iconCache: AppIconCache

    /// A model passed in is shared with the app's other consumers; without one the window builds its own
    /// from the same seams, which is how tests substitute the system.
    init(
        model: LauncherModel? = nil,
        workspace: WorkspaceProtocol = SystemWorkspace(),
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        eventSource: EventSourceProtocol = SystemEventSource(),
        fileSystem: FileSystemProtocol = SystemFileManager(),
        iconProvider: AppIconProviding = SystemAppIconProvider()
    ) {
        self.model = model ?? LauncherModel(
            workspace: workspace,
            pasteboard: pasteboard,
            eventSource: eventSource,
            fileSystem: fileSystem
        )
        self.iconProvider = iconProvider
        iconCache = AppIconCache(loader: iconProvider)
        super.init()
        setupWindow()
        window?.copyClipHandler = { [weak self] in self?.model.copySelection() ?? false }
        clipboardMenu.delegate = self
        connectModel()
        observeAccessibilityChanges()
        observeAsyncUpdates()
        observeWindowMovement()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The model reports through callbacks because this class draws by hand rather than by observation.
    private func connectModel() {
        model.onDismiss = { [weak self] in self?.hide() }
        model.onChange = { [weak self] change in
            guard let self, !isSuppressingModelChanges else { return }
            modelDidChange(change)
        }
    }

    private func modelDidChange(_ change: LauncherChange) {
        switch change {
        case let .results(preservedSelection):
            if preservedSelection {
                reloadRefreshedResults()
                return
            }
            reloadResults(animate: false)
            if !userHasOverriddenPinnedScrollSinceLastQueryChange {
                scrollResultsToTop(selectFirstRow: true)
            }
            // Update sidecar highlights (scroll-preserving) for clipboard mode
            if model.mode == .clipboard {
                refreshSidecarHighlightIfNeeded()
            }
        case .status:
            updateCaptureControl()
            updateStatusLabel()
            let status = model.status
            // A failed launch leaves the query as the next thing to fix.
            if model.mode == .applications, status != nil, status != lastShownStatus {
                window?.makeFirstResponder(searchField)
            }
            lastShownStatus = status
        }
    }

    /// Runs `body` without drawing the model's announcements, for resets the shell draws itself.
    private func withoutModelChanges(_ body: () -> Void) {
        isSuppressingModelChanges = true
        defer { isSuppressingModelChanges = false }
        body()
    }

    // MARK: - Accessibility Settings (US-005)

    /// Returns current accessibility settings from macOS
    private func getAccessibilitySettings() -> (reduceTransparency: Bool, increaseContrast: Bool, reduceMotion: Bool) {
        (
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
            // Delivered on the main queue, which the compiler cannot see through the Sendable block.
            MainActor.assumeIsolated { self?.applyAccessibilitySettings() }
        }
    }

    /// Observes main window movement to keep sidecar attached
    private func observeWindowMovement() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSidecarPosition() }
        }
    }

    /// Updates sidecar position to stay attached to main window
    private func updateSidecarPosition() {
        guard isSidecarVisible,
              let mainWindow = window,
              let sidecar = sidecarWindow else { return }

        let gap: CGFloat = 8
        let mainFrame = mainWindow.frame
        let sidecarOrigin = NSPoint(
            x: mainFrame.maxX + gap,
            y: mainFrame.origin.y
        )
        sidecar.setFrameOrigin(sidecarOrigin)
    }

    /// Icons load lazily, so a finished load redraws only the row that was waiting for it.
    private func observeAsyncUpdates() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("applebox.appIconCache.didLoad"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue, which the compiler cannot see through the Sendable block.
            // Read the payload here because Notification itself cannot cross into the isolated block.
            let bundlePath = notification.userInfo?["bundlePath"] as? String
            guard let self else { return }
            MainActor.assumeIsolated {
                guard isWindowVisible, model.mode == .applications, let bundlePath else { return }

                if let row = model.apps.rows.firstIndex(where: { $0.id == bundlePath }) {
                    tableView?.reloadData(
                        forRowIndexes: IndexSet(integer: row),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
        }
    }

    /// Applies current accessibility settings to all UI elements
    private func applyAccessibilitySettings() {
        let settings = getAccessibilitySettings()

        // Update main window
        if let window, let glassView = window.contentView as? NSVisualEffectView {
            updateGlassViewForAccessibility(glassView, settings: settings)

            // Update overlay and panels within the glass view
            for subview in glassView.subviews {
                if subview is NSVisualEffectView {
                    continue // Skip the glass view itself
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
        if let headerPanel {
            updatePanelForAccessibility(headerPanel, settings: settings, isSidecar: false)
        }

        // Reload table to update cards
        tableView?.reloadData()
    }

    /// Updates glass view material based on accessibility settings
    private func updateGlassViewForAccessibility(_ glassView: NSVisualEffectView, settings: (reduceTransparency: Bool, increaseContrast: Bool, reduceMotion: Bool)) {
        // When Reduce Transparency is enabled, reduce blur effect
        if settings.reduceTransparency {
            glassView.material = .sidebar // Less translucent material
            glassView.state = .active
        } else {
            glassView.material = .hudWindow // Original translucent material
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
            overlayOpacity = min(overlayOpacity + 0.2, 0.7) // Significantly increase opacity
        }

        // Adjust for Increase Contrast (strengthen strokes)
        if settings.increaseContrast {
            strokeOpacity = min(strokeOpacity + 0.25, 0.8) // Strengthen strokes
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
                layer.borderWidth = 1.0 // Thicker stroke
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
        model.setSearchService(service)
    }

    func setSearchShortcutHelp(_ help: String) {
        searchField?.setAccessibilityHelp(help)
    }

    func setClipboardManager(_ manager: ClipboardManager) {
        model.setClipboardManager(manager)
    }

    func prewarmAppIcons(applications: [ApplicationInfo]) {
        let bundlePaths = applications.map(\.bundlePath)
        DispatchQueue.global(qos: .utility).async { [iconCache] in
            iconCache.prewarm(bundlePaths: bundlePaths)
        }
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
        glassView.layer?.cornerRadius = 20 // Premium corner radius
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
        searchField.placeholderString = DesignTokens.Copy.searchApplicationsPlaceholder
        searchField.font = NSFont.systemFont(ofSize: 17)
        searchField.target = self
        searchField.action = #selector(handleSearch(_:))
        searchField.delegate = self
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.backgroundColor = .clear
        searchField.textColor = .labelColor
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false

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
        resultsPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor // Lighter stroke
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
        scrollView.drawsBackground = false // Prevent dark background drawing
        scrollView.contentView.drawsBackground = false // Clip view also needs this

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
        tableView.intercellSpacing = NSSize(width: 0, height: 6) // Spacing between card rows
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none // Custom selection drawing
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true

        // Accessibility for table view
        tableView.setAccessibilityIdentifier("AppleBoxResultsTable")
        tableView.setAccessibilityLabel("Search Results")
        tableView.setAccessibilityHelp("Use arrow keys to navigate results, Enter to select.")

        // Create single text column - match scrollView width for proper alignment
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.width = 544 // Match scrollView width to prevent right-side overflow
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
        let sidecarHeight: CGFloat = 400 // Match main window height

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
        glassView.layer?.cornerRadius = 20 // Premium corner radius
        glassView.layer?.masksToBounds = true
        if #available(macOS 11.0, *) {
            glassView.layer?.cornerCurve = .continuous
        }

        // Subtle readability overlay with premium stroke (LOWER CONTRAST for sidecar)
        // Reduced opacity for a more receded, blended appearance
        let overlayView = NSView(frame: glassView.bounds)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.16).cgColor // Reduced from 0.22
        overlayView.layer?.borderWidth = 0.5
        overlayView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor // Reduced from 0.3
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
        contentPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.09).cgColor // Reduced from 0.12
        contentPanel.layer?.cornerRadius = 18
        contentPanel.layer?.borderWidth = 0.5
        contentPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor // Reduced from 0.25
        if #available(macOS 11.0, *) {
            contentPanel.layer?.cornerCurve = .continuous
        }

        containerView.addSubview(contentPanel)
        glassView.addSubview(overlayView)
        glassView.addSubview(containerView)
        sidecarWindow.contentView = glassView

        self.sidecarWindow = sidecarWindow
        sidecarContentView = contentPanel
    }

    // MARK: - Sidecar Panel Methods

    /// Shows the sidecar panel positioned to the right of the main window.
    func showSidecar() {
        guard let mainWindow = window, let sidecar = sidecarWindow, model.mode == .clipboard else { return } // Only show in clipboard mode

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
        isSidecarVisible
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
        guard model.mode == .clipboard, let selected = selectedClip() else {
            hideSidecar()
            return
        }

        let item = selected.item

        // Rule 1: Show for images
        if item.contentType == .image {
            updateSidecarContent(for: item, matchedIndices: selected.matchedIndices)
            showSidecar()
            return
        }

        // Rule 2: Show for overflowing text
        if item.content.count > singleLineCharacterLimit || item.content.contains("\n") {
            updateSidecarContent(for: item, matchedIndices: selected.matchedIndices)
            showSidecar()
            return
        }

        // Rule 3: Hide otherwise
        hideSidecar()
    }

    /// The highlighted clip with its full text and match offsets, which rows deliberately omit.
    private func selectedClip() -> (item: ClipboardItem, matchedIndices: [Int])? {
        guard let selection = model.selection, model.clips.rows.indices.contains(selection) else { return nil }

        let id = model.clips.rows[selection].id
        guard let item = model.clips.item(id: id) else { return nil }
        return (item, model.clips.matchedIndices(id: id))
    }

    /// Updates the sidecar content view with the appropriate preview.
    private func updateSidecarContent(for item: ClipboardItem, matchedIndices: [Int] = []) {
        clearSidecarContent()

        // Clear sidecar text state when rebuilding
        sidecarTextView = nil
        sidecarTextScrollView = nil
        sidecarDisplayedItemID = nil
        sidecarHighlightedIndices = []

        guard let contentView = sidecarContentView else { return }

        if item.contentType == .image, let image = clipboardImageCache.image(for: item) ?? item.getImage() {
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
            let font = ClipKind.isCodeLike(item.content)
                ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                : NSFont.systemFont(ofSize: 13)

            // Apply highlighted attributed string
            textView.textStorage?.setAttributedString(
                attributedString(for: item.content, highlightingIndices: matchedIndices, font: font)
            )

            scrollView.documentView = textView
            scrollView.setAccessibilityIdentifier("SidecarTextPreview")
            scrollView.setAccessibilityLabel("Clipboard text preview")
            contentView.addSubview(scrollView)

            // Store references for scroll-preserving highlight updates
            sidecarTextView = textView
            sidecarTextScrollView = scrollView
            sidecarDisplayedItemID = item.id
            sidecarHighlightedIndices = matchedIndices
        }
    }

    /// Clears all subviews from the sidecar content view.
    private func clearSidecarContent() {
        sidecarContentView?.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Updates sidecar highlights without rebuilding the view (preserves scroll position).
    /// Called after search results change but the selected item remains the same.
    private func refreshSidecarHighlightIfNeeded() {
        guard model.mode == .clipboard else { return }
        guard let selected = selectedClip() else {
            // The previous clip is no longer actionable after the search changed.
            if isSidecarVisible {
                hideSidecar()
            }
            return
        }

        let item = selected.item

        // Keep the scroll position only when the same clip owns the preview.
        guard isSidecarVisible,
              item.contentType == .text,
              item.id == sidecarDisplayedItemID,
              let textView = sidecarTextView,
              let textStorage = textView.textStorage,
              let scrollView = sidecarTextScrollView
        else {
            // Different item or image; need full rebuild
            updateSidecarVisibility()
            return
        }

        let newIndices = selected.matchedIndices

        // Skip if highlights haven't changed
        guard newIndices != sidecarHighlightedIndices else { return }

        // Preserve scroll position and selection
        let savedScrollOrigin = scrollView.contentView.bounds.origin
        let savedSelection = textView.selectedRange()

        // Clear previous highlights
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        applyHighlights(to: textStorage, in: item.content, at: newIndices)

        sidecarHighlightedIndices = newIndices

        // Restore scroll position and selection
        scrollView.contentView.scroll(to: savedScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.setSelectedRange(savedSelection)
    }

    func toggle(mode: SearchMode? = nil) {
        if isWindowVisible {
            // If window is visible, switch to the requested mode or hide
            if let mode, mode != model.mode {
                switchToMode(mode)
            } else {
                hide()
            }
        } else {
            show(mode: mode)
        }
    }

    @objc private func resultsDidScroll(_: Notification) {
        guard !isPerformingProgrammaticScroll else { return }
        userHasOverriddenPinnedScrollSinceLastQueryChange = true
    }

    private func scrollResultsToTop(selectFirstRow: Bool) {
        guard let scrollView else { return }

        isPerformingProgrammaticScroll = true
        defer { isPerformingProgrammaticScroll = false }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        guard selectFirstRow, let tableView else { return }

        if model.resultCount > 0 {
            if model.selection != 0 || tableView.selectedRow != 0 {
                model.select(0)
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            tableView.scrollRowToVisible(0)
        } else {
            model.select(-1)
            tableView.deselectAll(nil)
        }
    }

    private func reloadResults(animate: Bool) {
        // Reloading drops the table's selection; the model, not the table, decides what is selected.
        let wasNavigating = isNavigatingProgrammatically
        isNavigatingProgrammatically = true
        tableView?.reloadData()
        isNavigatingProgrammatically = wasNavigating
        tableView?.menu = model.mode == .clipboard ? clipboardMenu : nil
        updateEmptyResultsLabel()
        updateCaptureControl()
        updateStatusLabel()
        if animate {
            animateResultsUpdateIfAppropriate()
        }
    }

    private func updateCaptureControl() {
        guard let searchField else { return }
        guard model.mode == .clipboard, model.clips.manager != nil, let headerPanel else {
            captureButton?.isHidden = true
            if let fullSearchFieldWidth {
                searchField.frame.size.width = fullSearchFieldWidth
            }
            return
        }

        let button = captureButton ?? makeCaptureButton(in: headerPanel, beside: searchField)
        let paused = model.clips.isPaused
        button.title = paused ? DesignTokens.Copy.resumeCapture : DesignTokens.Copy.pauseCapture
        button.setAccessibilityHelp(paused ? DesignTokens.Copy.capturePausedHelp : DesignTokens.Copy.captureActiveHelp)
        button.isHidden = false
        searchField.frame.size.width = button.frame.minX - searchField.frame.minX - captureButtonSpacing
    }

    private func makeCaptureButton(in headerPanel: NSView, beside searchField: NSSearchField) -> NSButton {
        // Size for the longer title to keep the query field stable across a pause.
        let button = NSButton(title: DesignTokens.Copy.resumeCapture, target: self, action: #selector(toggleCapture))
        button.sizeToFit()
        let frame = headerPanel.bounds
        button.setFrameOrigin(NSPoint(x: frame.maxX - button.frame.width - captureButtonSpacing, y: frame.midY - button.frame.height / 2))
        headerPanel.addSubview(button)
        fullSearchFieldWidth = searchField.frame.width
        captureButton = button
        return button
    }

    @objc private func toggleCapture() {
        model.toggleCapture()
    }

    /// Keep recovery guidance visible without covering the query or existing results.
    private func updateStatusLabel() {
        guard let message = model.status?.message, let content = headerPanel?.superview else {
            statusLabel?.isHidden = true
            return
        }

        let label = statusLabel ?? makeStatusLabel(in: content, message: message)
        label.stringValue = message
        label.isHidden = false
    }

    private func makeStatusLabel(in content: NSView, message: String) -> NSTextField {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.alignment = .center
        // Match the frame-based layout of the launcher so the footer occupies the bottom inset.
        label.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: statusLabelHeight)
        label.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(label, positioned: .above, relativeTo: nil)
        statusLabel = label
        return label
    }

    /// Explain an empty query result while leaving the search field in place.
    private func updateEmptyResultsLabel() {
        guard let message = model.emptyMessage else {
            emptyResultsLabel?.isHidden = true
            return
        }
        if let label = emptyResultsLabel {
            label.stringValue = message
            label.isHidden = false
            return
        }

        guard let scrollView, let panel = scrollView.superview else { return }

        let label = NSTextField(labelWithString: message)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        emptyResultsLabel = label
    }

    /// Keep the action index and the table selection in sync even after manual scrolling.
    private func reloadRefreshedResults() {
        let previousRow = tableView?.selectedRow ?? -1
        let wasVisible = tableView.map { table in
            previousRow >= 0 && NSLocationInRange(previousRow, table.rows(in: table.visibleRect))
        } ?? false

        isNavigatingProgrammatically = true
        isPerformingProgrammaticScroll = true
        defer {
            isNavigatingProgrammatically = false
            isPerformingProgrammaticScroll = false
        }

        let row = model.selection
        reloadResults(animate: false)
        tableView?.selectRowIndexes(row.map(IndexSet.init(integer:)) ?? [], byExtendingSelection: false)
        if wasVisible, let row {
            tableView?.scrollRowToVisible(row)
        }

        if row == nil || !isSidecarVisible {
            updateSidecarVisibility()
        } else {
            refreshSidecarHighlightIfNeeded()
        }
    }

    /// Draws whatever the model holds after the shell reset it, in the order the window needs.
    private func presentCurrentResults() {
        reloadResults(animate: false)
        scrollResultsToTop(selectFirstRow: true)
        updateSidecarVisibility()
    }

    private func animateResultsUpdateIfAppropriate() {
        guard isWindowVisible, let scrollView else { return }
        let settings = getAccessibilitySettings()
        guard !settings.reduceMotion else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let minimumInterval: TimeInterval = 0.10
        if now - lastResultsAnimationUptime < minimumInterval {
            return
        }
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
        withoutModelChanges { model.switchMode(to: mode) }
        presentFreshSession()
        print("Switched to \(mode) mode")
    }

    /// Draws the model's freshly reset session: empty field, mode placeholder, first row selected.
    private func presentFreshSession() {
        if let searchField {
            searchField.stringValue = ""
            searchField.placeholderString = model.placeholder
            window?.makeFirstResponder(searchField)
        }

        userHasOverriddenPinnedScrollSinceLastQueryChange = false
        presentCurrentResults()
    }

    func show(mode: SearchMode? = nil) {
        guard let window else { return }
        // The model records the paste target, so it must see the world before AppleBox takes focus.
        withoutModelChanges { model.show(mode: mode) }

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

        presentFreshSession()

        isWindowVisible = true
        print("Window shown in \(model.mode) mode")
    }

    func hide() {
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        model.hide()
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

        if query != model.query {
            userHasOverriddenPinnedScrollSinceLastQueryChange = false
        }
        model.setQuery(query)
    }

    // MARK: - Focus Treatment (US-002)

    @objc private func searchFieldDidBeginEditing(_: Notification) {
        updateSearchFieldFocusState(focused: true)
    }

    @objc private func searchFieldDidEndEditing(_: Notification) {
        updateSearchFieldFocusState(focused: false)
    }

    /// Updates the header panel styling to show premium focus treatment.
    /// - Adds subtle inner glow and thin accent stroke when focused
    /// - Respects Reduce Motion for animations and Increase Contrast for visibility
    private func updateSearchFieldFocusState(focused: Bool) {
        guard let headerPanel, let layer = headerPanel.layer else { return }

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

    private func navigateResults(direction: Int) {
        userHasOverriddenPinnedScrollSinceLastQueryChange = true
        guard model.resultCount > 0 else { return }

        let previousIndex = model.selection ?? -1
        model.moveSelection(by: direction)
        let newIndex = model.selection ?? -1

        if newIndex < 0 {
            // Going up from first element (or no selection) - focus search field
            tableView?.deselectAll(nil)
            // Deselect the previous card visually
            if let tableView {
                updateCardSelectionVisuals(tableView: tableView, previousRow: previousIndex, currentRow: -1)
            }
            window?.makeFirstResponder(searchField)
            print("Focus returned to search field")
            return
        } else if newIndex == previousIndex {
            // At last element, don't wrap - stay at last
            return
        }

        // Prevent tableViewSelectionDidChange from double-updating visuals
        isNavigatingProgrammatically = true
        tableView?.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(newIndex)
        isNavigatingProgrammatically = false

        // Manually update card visuals with correct previous/current indices
        if let tableView {
            updateCardSelectionVisuals(tableView: tableView, previousRow: previousIndex, currentRow: newIndex)
        }
        updateSidecarVisibility()

        if model.mode == .clipboard {
            // Row numbers identify navigation without exposing the copied material.
            logger.debug("Selected clipboard history row \(newIndex, privacy: .public)")
        } else {
            print("Selected: \(newIndex) - \(model.apps.rows[newIndex].name)")
        }
    }

    private func handleEnterKey() {
        guard let selection = model.selection, selection < model.resultCount else {
            // Leave the query editable when there is no selected result to act on.
            window?.makeFirstResponder(searchField)
            return
        }

        model.activateSelection()
    }

    @objc private func copyClickedClip(_ action: NSMenuItem) {
        guard let id = action.representedObject as? UUID else { return }
        model.copyClip(id: id)
    }

    @objc private func deleteClickedClip(_ action: NSMenuItem) {
        guard let id = action.representedObject as? UUID else { return }
        model.deleteClip(id: id)
    }

    @objc private func confirmClearClipboardHistory(_: NSMenuItem) {
        guard model.mode == .clipboard, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = DesignTokens.Copy.clearHistoryTitle
        alert.informativeText = DesignTokens.Copy.clearHistoryExplanation
        // Return chooses Cancel so a repeated keypress cannot erase the archive.
        alert.addButton(withTitle: DesignTokens.Copy.cancel).keyEquivalent = CopyClipShortcut.key
        alert.addButton(withTitle: DesignTokens.Copy.clearHistoryButton).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.model.clearHistory()
        }
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        let clickedRow = sender.clickedRow
        guard clickedRow >= 0, clickedRow < model.resultCount else { return }

        model.select(clickedRow)
        model.activateSelection()
    }

    func isVisible() -> Bool {
        isWindowVisible
    }

    // MARK: - Test Helpers

    /// Returns the current search mode (for testing)
    func getCurrentSearchMode() -> SearchMode {
        model.mode
    }

    /// Returns the current placeholder text (for testing)
    func getPlaceholderText() -> String? {
        searchField?.placeholderString
    }

    /// Returns the number of results currently displayed (for testing)
    func getResultCount() -> Int {
        model.resultCount
    }

    /// Returns the current search text (for testing)
    func getSearchText() -> String? {
        searchField?.stringValue
    }

    /// Simulates typing in the search field (for testing).
    /// Searches before returning, so tests can read the rows at once.
    func simulateSearch(query: String) {
        searchField?.stringValue = query
        if query != model.query {
            userHasOverriddenPinnedScrollSinceLastQueryChange = false
        }
        model.setQueryImmediately(query)
    }

    /// Returns the content view for snapshot testing
    func getContentView() -> NSView? {
        window?.contentView
    }

    /// Returns the window for snapshot testing
    func getWindow() -> NSWindow? {
        window
    }

    /// Sets search results directly for snapshot testing
    func setSearchResultsForTesting(_ results: [SearchResult]) {
        withoutModelChanges { model.setApplicationResults(results) }
        tableView?.reloadData()
        if !results.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Sets clipboard results directly for snapshot testing
    func setClipboardResultsForTesting(_ items: [ClipboardItem]) {
        setClipboardSearchResultsForTesting(
            items.map { ClipboardSearchResult(item: $0, relevanceScore: 0, matchedIndices: []) },
            updatingSidecar: false
        )
        reloadResults(animate: false)
    }

    /// Sets clipboard search results with matchedIndices for testing highlight behavior
    func setClipboardSearchResultsForTesting(_ results: [ClipboardSearchResult]) {
        setClipboardSearchResultsForTesting(results, updatingSidecar: true)
    }

    private func setClipboardSearchResultsForTesting(_ results: [ClipboardSearchResult], updatingSidecar: Bool) {
        withoutModelChanges {
            model.setClipboardMatches(results.map {
                ClipboardManager.ClipboardSearchMatch(item: $0.item, score: $0.relevanceScore, matchedIndices: $0.matchedIndices)
            })
        }
        searchField?.placeholderString = model.placeholder
        tableView?.reloadData()
        if !results.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        if updatingSidecar {
            updateSidecarVisibility()
        }
    }

    /// Select a specific row for snapshot testing
    func selectRowForTesting(_ row: Int) {
        guard row >= 0, row < model.resultCount else { return }
        model.select(row)
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView?.scrollRowToVisible(row)
    }

    // MARK: - Accessibility Test Helpers

    /// Returns the search field for accessibility testing
    func getSearchField() -> NSSearchField? {
        searchField
    }

    /// Returns the table view for accessibility testing
    func getTableView() -> NSTableView? {
        tableView
    }

    /// Returns the cell view at a specific row for accessibility testing
    func getCellViewForTesting(at row: Int) -> NSView? {
        guard let tableView else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
    }

    /// Returns the selected row index for testing
    func getSelectedRowIndex() -> Int {
        model.selection ?? -1
    }

    // MARK: - Sidecar Test Helpers

    /// Returns the sidecar window for testing
    func getSidecarWindow() -> NSWindow? {
        sidecarWindow
    }

    /// Returns the sidecar content view for testing
    func getSidecarContentView() -> NSView? {
        sidecarContentView
    }
}

// MARK: - NSTableViewDataSource

extension WindowManager: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        model.resultCount
    }
}

// MARK: - NSTableViewDelegate

extension WindowManager: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        // Display based on search mode
        if model.mode == .clipboard {
            makeClipboardCell(tableView: tableView, row: row)
        } else {
            makeApplicationCell(tableView: tableView, row: row)
        }
    }

    private func makeClipboardCell(tableView: NSTableView, row: Int) -> NSView? {
        guard row >= 0, row < model.clips.rows.count else { return nil }

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

            // Text field inside card (single line only - sidecar shows full content)
            let textField = NSTextField()
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.backgroundColor = .clear
            textField.font = NSFont.systemFont(ofSize: 14)
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.cell?.usesSingleLineMode = true
            textField.tag = 200
            cardContainer?.addSubview(textField)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cardContainer!.leadingAnchor, constant: 16),
                textField.trailingAnchor.constraint(equalTo: cardContainer!.trailingAnchor, constant: -16),
                textField.centerYAnchor.constraint(equalTo: cardContainer!.centerYAnchor),
            ])
        }

        let clip = model.clips.rows[row]
        let displayContent = clip.preview

        if let textField = cardContainer?.viewWithTag(200) as? NSTextField {
            textField.attributedStringValue = attributedString(
                for: displayContent,
                highlighting: clip.runs,
                font: textField.font ?? NSFont.systemFont(ofSize: 14)
            )
        }

        // Apply initial selection styling
        let isSelected = (model.selection == row)
        applyCardSelectionStyle(to: cardContainer, isSelected: isSelected, animated: false)

        // Accessibility
        cardContainer?.setAccessibilityIdentifier("ClipboardRow_\(row)")
        cardContainer?.setAccessibilityLabel("Clipboard item: \(displayContent)")
        cardContainer?.setAccessibilityHelp("Press Enter to copy this item to clipboard")

        return cardContainer
    }

    private func makeApplicationCell(tableView: NSTableView, row: Int) -> NSView? {
        guard row >= 0, row < model.apps.rows.count else { return nil }

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
                textField.centerYAnchor.constraint(equalTo: cardContainer!.centerYAnchor),
            ])
        }

        let application = model.apps.rows[row]

        // Get app icon
        if let imageView = cardContainer?.viewWithTag(100) as? NSImageView {
            let icon = iconCache.icon(forBundlePath: application.id)
            icon.size = NSSize(width: iconSize, height: iconSize)
            imageView.image = icon
        }

        let location = application.location
        if let textField = cardContainer?.viewWithTag(101) as? NSTextField {
            configureApplicationTitle(textField, row: application)
        }

        // Apply initial selection styling
        let isSelected = (model.selection == row)
        applyCardSelectionStyle(to: cardContainer, isSelected: isSelected, animated: false)

        // Accessibility
        cardContainer?.setAccessibilityIdentifier("ApplicationRow_\(row)")
        let accessibleName = location.map { "\(application.name), \($0)" } ?? application.name
        cardContainer?.setAccessibilityLabel("Application: \(accessibleName)")
        cardContainer?.setAccessibilityHelp("Press Enter to launch this application")

        return cardContainer
    }

    private func configureApplicationTitle(_ field: NSTextField, row: AppRowData) {
        let location = row.location
        let title = attributedString(
            for: row.name,
            highlighting: row.runs,
            font: field.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        )

        // Restore the default styling when a duplicate row is reused for a unique result.
        field.lineBreakMode = location == nil ? .byTruncatingTail : .byTruncatingMiddle
        field.toolTip = location
        guard let location else {
            field.attributedStringValue = title
            return
        }

        let fullTitle = NSMutableAttributedString(attributedString: title)
        fullTitle.append(NSAttributedString(string: applicationLocationSeparator + location, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ]))
        field.attributedStringValue = fullTitle
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard let tableView else { return }

        // Skip if navigating programmatically (handled in navigateResults)
        guard !isNavigatingProgrammatically else { return }

        let previousSelection = model.selection ?? -1
        model.select(tableView.selectedRow)

        // Update card styling for previous and new selection
        updateCardSelectionVisuals(tableView: tableView, previousRow: previousSelection, currentRow: model.selection ?? -1)

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
        guard let card, let layer = card.layer else { return }

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

    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
        44 // Increased height for premium card feel
    }

    // MARK: - Attributed String Highlighting

    /// Draws precomputed match runs in the accent color, so rows highlight exactly what the model matched.
    private func attributedString(for text: String, highlighting runs: [MatchRun], font: NSFont) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        for run in runs {
            attributedString.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: NSRange(run.range, in: text))
        }
        return attributedString
    }

    /// Creates an attributed string with matched characters highlighted using the system accent color.
    private func attributedString(for text: String, highlightingIndices indices: [Int], font: NSFont) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])

        applyHighlights(to: attributedString, in: text, at: indices)
        return attributedString
    }

    /// AppKit needs a UTF-16 range spanning the entire displayed character.
    private func applyHighlights(to attributed: NSMutableAttributedString, in text: String, at indices: [Int]) {
        var cursor = text.startIndex
        var cursorOffset = 0
        for offset in indices where offset >= cursorOffset {
            guard let start = text.index(cursor, offsetBy: offset - cursorOffset, limitedBy: text.endIndex),
                  start != text.endIndex else { break }
            let end = text.index(after: start)
            attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: NSRange(start ..< end, in: text))
            cursor = end
            cursorOffset = offset + 1
        }
    }
}

extension WindowManager: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard model.mode == .clipboard else { return }

        if let row = tableView?.clickedRow, model.clips.rows.indices.contains(row) {
            // Bind the menu to the clip even if live capture reorders rows before a click.
            let id = model.clips.rows[row].id
            let copy = NSMenuItem(title: DesignTokens.Copy.copyClip, action: #selector(copyClickedClip(_:)), keyEquivalent: CopyClipShortcut.key)
            copy.keyEquivalentModifierMask = CopyClipShortcut.modifiers
            copy.target = self
            copy.representedObject = id
            menu.addItem(copy)

            let delete = NSMenuItem(title: DesignTokens.Copy.deleteClip, action: #selector(deleteClickedClip(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = id
            menu.addItem(delete)
            menu.addItem(.separator())
        }

        let clear = NSMenuItem(title: DesignTokens.Copy.clearHistoryMenu, action: #selector(confirmClearClipboardHistory(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
}

/// NSWindowDelegate to handle window events
extension WindowManager: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Hide when main window loses focus (clicking outside)
        // But not when sidecar gains focus (it's part of our UI)
        guard notification.object as? NSWindow === window, sidecarWindow?.isKeyWindow != true,
              window?.attachedSheet == nil else { return }
        hide()
    }
}

/// NSSearchFieldDelegate to handle arrow keys in search field
extension WindowManager: NSSearchFieldDelegate {
    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            navigateResults(direction: -1)
            return true
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            navigateResults(direction: 1)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            handleEnterKey()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleEscapeFromSearchField()
            return true
        }
        return false
    }

    private func handleEscapeFromSearchField() {
        // When text exists, Esc should clear + hide.
        let hadText = searchField.map { !$0.stringValue.isEmpty } ?? false
        let previousSelection = model.selection ?? -1
        if hadText, let searchField {
            // Typing normally reaches the model through the search action; this covers text it has not seen.
            model.query = searchField.stringValue
            searchField.stringValue = ""
        }

        // The model clears the query and selection, then asks the shell to hide.
        model.escape()

        if hadText {
            tableView?.deselectAll(nil)
            if let tableView {
                updateCardSelectionVisuals(tableView: tableView, previousRow: previousSelection, currentRow: -1)
            }
        }
    }
}
