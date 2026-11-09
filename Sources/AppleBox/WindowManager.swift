import AppKit
import CoreGraphics
import CryptoKit
import OSLog
import QuartzCore

// MARK: - Search Mode

enum SearchMode {
    case applications
    case clipboard
}

/// Result type for clipboard search
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

final class AppIconCache {
    private let loader: AppIconProviding
    private let cache = NSCache<NSString, NSImage>()
    private let loadQueue = DispatchQueue(label: "applebox.icons.load", qos: .utility)

    private let inFlightQueue = DispatchQueue(label: "applebox.icons.inflight")
    private var inFlight: Set<String> = []

    private let placeholder: NSImage

    init(loader: AppIconProviding) {
        self.loader = loader
        placeholder = NSImage(size: NSSize(width: 24, height: 24))
    }

    func icon(forBundlePath bundlePath: String) -> NSImage {
        if let cached = cache.object(forKey: bundlePath as NSString) {
            return cached
        }

        // Tests and previews inject a lightweight icon provider; keep it synchronous for deterministic snapshots.
        if !(loader is SystemAppIconProvider) {
            let icon = loader.icon(forBundlePath: bundlePath)
            cache.setObject(icon, forKey: bundlePath as NSString)
            return icon
        }

        scheduleLoadIfNeeded(bundlePath: bundlePath, notify: true)
        return placeholder
    }

    func prewarm(bundlePaths: [String]) {
        for path in bundlePaths {
            if cache.object(forKey: path as NSString) == nil {
                scheduleLoadIfNeeded(bundlePath: path, notify: false)
            }
        }
    }

    private func scheduleLoadIfNeeded(bundlePath: String, notify: Bool) {
        let shouldStart = inFlightQueue.sync { () -> Bool in
            if inFlight.contains(bundlePath) {
                return false
            }
            inFlight.insert(bundlePath)
            return true
        }

        guard shouldStart else { return }

        loadQueue.async { [weak self] in
            guard let self else { return }
            let icon = loader.icon(forBundlePath: bundlePath)
            cache.setObject(icon, forKey: bundlePath as NSString)

            inFlightQueue.sync {
                _ = self.inFlight.remove(bundlePath)
            }

            if notify {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("applebox.appIconCache.didLoad"),
                        object: nil,
                        userInfo: ["bundlePath": bundlePath]
                    )
                }
            }
        }
    }
}

final class ClipboardImageCache {
    private let cache = NSCache<NSString, NSImage>()

    func image(for item: ClipboardItem) -> NSImage? {
        guard item.contentType == .image, let base64 = item.imageData else { return nil }

        let key = Self.key(forBase64: base64)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func key(forBase64 base64: String) -> String {
        // Keep keys small even for huge images.
        let digest = SHA256.hash(data: Data(base64.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class RecentApplicationsStore {
    private let fileSystem: FileSystemProtocol
    private let storageURL: URL

    private let queue = DispatchQueue(label: "applebox.recentApps", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "applebox.recentApps.persistence", qos: .utility)

    private let fileName = "recent_applications.json"
    private let maxCount = 50

    private var recentBundlePaths: [String] = []

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem

        let appSupportURL = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileSystem.homeDirectoryForCurrentUser
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        if !fileSystem.fileExists(atPath: appDirectory.path) {
            try? fileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        storageURL = appDirectory.appendingPathComponent(fileName)

        recentBundlePaths = loadRecentsFromDisk()
    }

    func orderedApplications(from applications: [ApplicationInfo]) -> [ApplicationInfo] {
        let snapshot = queue.sync { recentBundlePaths }
        var remaining = Dictionary(uniqueKeysWithValues: applications.map { ($0.bundlePath, $0) })
        var ordered: [ApplicationInfo] = []
        ordered.reserveCapacity(applications.count)

        for bundlePath in snapshot {
            if let app = remaining.removeValue(forKey: bundlePath) {
                ordered.append(app)
            }
        }

        let tail = remaining.values.sorted { $0.name < $1.name }
        ordered.append(contentsOf: tail)
        return ordered
    }

    func recordLaunch(bundlePath: String) {
        let snapshot = queue.sync { () -> [String] in
            var updated = recentBundlePaths.filter { $0 != bundlePath }
            updated.insert(bundlePath, at: 0)
            if updated.count > maxCount {
                updated = Array(updated.prefix(maxCount))
            }
            recentBundlePaths = updated
            return updated
        }

        persistRecentsAsync(snapshot)
    }

    func seedIfEmpty(with bundlePaths: [String]) {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(bundlePaths.count)

        for path in bundlePaths {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }

        guard !ordered.isEmpty else { return }

        let snapshot = queue.sync { () -> [String]? in
            guard recentBundlePaths.isEmpty else { return nil }
            let limited = Array(ordered.prefix(maxCount))
            recentBundlePaths = limited
            return limited
        }

        guard let snapshot else { return }
        persistRecentsAsync(snapshot)
    }

    private func persistRecentsAsync(_ snapshot: [String]) {
        persistenceQueue.async { [snapshot, storageURL, fileSystem] in
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(snapshot)
                _ = fileSystem.createFile(atPath: storageURL.path, contents: data, attributes: nil)
            } catch {
                // Best-effort persistence.
            }
        }
    }

    private func loadRecentsFromDisk() -> [String] {
        guard fileSystem.fileExists(atPath: storageURL.path), let data = fileSystem.contents(atPath: storageURL.path) else { return [] }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode([String].self, from: data)
        } catch {
            return []
        }
    }
}

/// Custom NSWindow that handles key events
class AppleBoxWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    var arrowUpHandler: (() -> Void)?
    var arrowDownHandler: (() -> Void)?
    var enterHandler: (() -> Void)?

    override var canBecomeKey: Bool {
        true
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
    private let searchDebounceInterval: TimeInterval = 0.0

    private let searchQueue = DispatchQueue(label: "applebox.window.search", qos: .userInteractive)
    private var searchComputeWorkItem: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []

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
    private let workspace: WorkspaceProtocol
    private let pasteboard: PasteboardProtocol
    private let eventSource: EventSourceProtocol
    private let fileSystem: FileSystemProtocol
    private let iconProvider: AppIconProviding
    private let iconCache: AppIconCache
    private let recentApplicationsStore: RecentApplicationsStore

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
        iconCache = AppIconCache(loader: iconProvider)
        recentApplicationsStore = RecentApplicationsStore(fileSystem: fileSystem)
        super.init()
        setupWindow()
        observeAccessibilityChanges()
        observeAsyncUpdates()
        observeWorkspaceActivity()
        observeWindowMovement()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
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
            self?.applyAccessibilitySettings()
        }
    }

    /// Observes main window movement to keep sidecar attached
    private func observeWindowMovement() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateSidecarPosition()
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

    private func observeAsyncUpdates() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("applebox.appIconCache.didLoad"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, isWindowVisible, searchMode == .applications, let bundlePath = notification.userInfo?["bundlePath"] as? String else { return }

            if let row = searchResults.firstIndex(where: { $0.application.bundlePath == bundlePath }) {
                tableView?.reloadData(
                    forRowIndexes: IndexSet(integer: row),
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("applebox.clipboardHistory.didUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, isWindowVisible, searchMode == .clipboard else { return }

            scheduleSearch(query: searchField?.stringValue ?? "", preservingSelection: true)
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("applebox.applicationIndex.didUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, isWindowVisible, searchMode == .applications else { return }

            searchService?.resetCache()
            scheduleSearch(query: searchField?.stringValue ?? "", preservingSelection: true)
        }
    }

    private func observeWorkspaceActivity() {
        guard workspace is SystemWorkspace else { return }

        let center = NSWorkspace.shared.notificationCenter

        let runningBundles = NSWorkspace.shared.runningApplications
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { app -> String? in
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
                return app.bundleURL?.path
            }
        recentApplicationsStore.seedIfEmpty(with: runningBundles)

        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleURL = app.bundleURL,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

            recentApplicationsStore.recordLaunch(bundlePath: bundleURL.path)

            guard isWindowVisible, searchMode == .applications else { return }
            let query = searchField?.stringValue ?? ""
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            updateApplicationResultsForEmptyQuery(animate: false, preservingSelection: true)
        }

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main,
            using: handler
        )

        let activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
            using: handler
        )

        workspaceObservers = [launchObserver, activateObserver]
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
        searchService = service
        searchService?.resetCache()
    }

    func setClipboardManager(_ manager: ClipboardManager) {
        clipboardManager = manager
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
        searchField.placeholderString = "Search applications..."
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
        guard let mainWindow = window, let sidecar = sidecarWindow, searchMode == .clipboard else { return } // Only show in clipboard mode

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
        guard searchMode == .clipboard, selectedRowIndex >= 0 && selectedRowIndex < clipboardResults.count else {
            hideSidecar()
            return
        }

        let result = clipboardResults[selectedRowIndex]
        let item = result.item

        // Rule 1: Show for images
        if item.contentType == .image {
            updateSidecarContent(for: item, matchedIndices: result.matchedIndices)
            showSidecar()
            return
        }

        // Rule 2: Show for overflowing text
        if item.content.count > singleLineCharacterLimit || item.content.contains("\n") {
            updateSidecarContent(for: item, matchedIndices: result.matchedIndices)
            showSidecar()
            return
        }

        // Rule 3: Hide otherwise
        hideSidecar()
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
            let font = isCodeLike(item.content)
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
        guard searchMode == .clipboard, isSidecarVisible, selectedRowIndex >= 0, selectedRowIndex < clipboardResults.count else { return }

        let result = clipboardResults[selectedRowIndex]
        let item = result.item

        // Keep the scroll position only when the same clip owns the preview.
        guard item.contentType == .text,
              item.id == sidecarDisplayedItemID,
              let textView = sidecarTextView,
              let textStorage = textView.textStorage,
              let scrollView = sidecarTextScrollView
        else {
            // Different item or image; need full rebuild
            updateSidecarVisibility()
            return
        }

        let newIndices = result.matchedIndices

        // Skip if highlights haven't changed
        guard newIndices != sidecarHighlightedIndices else { return }

        // Preserve scroll position and selection
        let savedScrollOrigin = scrollView.contentView.bounds.origin
        let savedSelection = textView.selectedRange()

        // Clear previous highlights
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Apply new highlights
        let highlightColor = NSColor.controlAccentColor
        for charIndex in newIndices {
            guard charIndex < item.content.count else { continue }
            let stringIndex = item.content.index(item.content.startIndex, offsetBy: charIndex)
            let utf16Offset = item.content.utf16.distance(from: item.content.utf16.startIndex, to: stringIndex)
            let range = NSRange(location: utf16Offset, length: 1)
            guard range.location + range.length <= textStorage.length else { continue }
            textStorage.addAttribute(.foregroundColor, value: highlightColor, range: range)
        }

        sidecarHighlightedIndices = newIndices

        // Restore scroll position and selection
        scrollView.contentView.scroll(to: savedScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.setSelectedRange(savedSelection)
    }

    /// Heuristic to detect code-like content for monospace formatting.
    /// Detects: common code patterns, indentation, brackets, semicolons, etc.
    private func isCodeLike(_ text: String) -> Bool {
        // Code indicators
        let codePatterns = [
            "func ", "class ", "struct ", "enum ", "let ", "var ", "import ", // Swift
            "function ", "const ", "=>", "===", "!==", // JavaScript
            "def ", "if __name__", "import ", "from ", // Python
            "{", "}", "[", "]", "();", "();", "->", "::", // Common syntax
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
            if let mode, mode != searchMode {
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

        let count = searchMode == .clipboard ? clipboardResults.count : searchResults.count
        if count > 0 {
            if selectedRowIndex != 0 || tableView.selectedRow != 0 {
                selectedRowIndex = 0
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
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

    /// Reordering can move a result without changing what the user selected.
    private func refreshedRow<Result>(
        from previous: [Result], to results: [Result], identifiedBy identity: KeyPath<Result, some Equatable>
    ) -> Int? {
        if previous.isEmpty {
            return results.indices.first
        }
        guard previous.indices.contains(selectedRowIndex) else { return nil }

        let selected = previous[selectedRowIndex][keyPath: identity]
        return results.firstIndex { $0[keyPath: identity] == selected }
    }

    /// Keep the action index and the table selection in sync even after manual scrolling.
    private func reloadRefreshedResults(selecting row: Int?) {
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

        selectedRowIndex = row ?? -1
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

    private func updateApplicationResultsForEmptyQuery(animate: Bool, preservingSelection: Bool = false) {
        guard searchMode == .applications, let searchService else { return }

        let orderedApplications = recentApplicationsStore.orderedApplications(from: searchService.allApplications())
        let results = orderedApplications.map {
            SearchResult(application: $0, score: 0, matchedIndices: [])
        }
        let row = preservingSelection ? refreshedRow(from: searchResults, to: results, identifiedBy: \.application.bundlePath) : nil
        searchResults = results
        clipboardResults = []
        if preservingSelection {
            reloadRefreshedResults(selecting: row)
            return
        }

        selectedRowIndex = results.isEmpty ? -1 : 0
        reloadResults(animate: animate)
        if !userHasOverriddenPinnedScrollSinceLastQueryChange {
            scrollResultsToTop(selectFirstRow: true)
        }
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
        searchMode = mode

        if let searchField {
            if mode == .clipboard {
                searchField.stringValue = "" // Don't show ">" in clipboard mode
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

        lastSearchQuery = searchField?.stringValue ?? ""
        userHasOverriddenPinnedScrollSinceLastQueryChange = false

        if mode == .applications {
            updateApplicationResultsForEmptyQuery(animate: false)
        } else {
            reloadResults(animate: false)
            scrollResultsToTop(selectFirstRow: true)
            updateSidecarVisibility()
        }

        print("Switched to \(mode) mode")
    }

    func show(mode: SearchMode? = nil) {
        guard let window else { return }

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
        if let mode {
            searchMode = mode
        } else {
            searchMode = .applications
        }

        // Configure based on mode
        if let searchField {
            if searchMode == .clipboard {
                searchField.stringValue = "" // Don't show ">" in clipboard mode
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

        lastSearchQuery = searchField?.stringValue ?? ""
        userHasOverriddenPinnedScrollSinceLastQueryChange = false

        if searchMode == .applications {
            updateApplicationResultsForEmptyQuery(animate: false)
        } else {
            reloadResults(animate: false)
            scrollResultsToTop(selectFirstRow: true)
            updateSidecarVisibility()
        }

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

        if searchDebounceInterval <= 0 {
            searchDebounceWorkItem = nil
            scheduleSearch(query: query)
            return
        }

        // Debounce search to avoid per-keystroke overhead
        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduleSearch(query: query)
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceInterval, execute: workItem)
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

    private func scheduleSearch(query: String, preservingSelection: Bool = false) {
        // Cancel any pending async search
        searchComputeWorkItem?.cancel()
        searchComputeWorkItem = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query in applications mode -> show recent apps
        if searchMode == .applications, trimmedQuery.isEmpty {
            searchService?.resetCache()
            updateApplicationResultsForEmptyQuery(animate: false, preservingSelection: preservingSelection)
            return
        }

        #if DEBUG
            let start = ProcessInfo.processInfo.systemUptime
        #endif

        // INSTANT SEARCH: Execute synchronously on main thread
        // The optimized FuzzyMatcher is fast enough (<1ms for 500 items)
        let row: Int?
        switch searchMode {
        case .clipboard:
            let matches = clipboardManager?.searchHistoryWithMatches(query: query) ?? []
            let results = matches.map { match in
                ClipboardSearchResult(item: match.item, relevanceScore: match.score, matchedIndices: match.matchedIndices)
            }

            row = preservingSelection ? refreshedRow(from: clipboardResults, to: results, identifiedBy: \.item.id) : nil
            searchResults = []
            clipboardResults = results

        case .applications:
            let results = searchService?.search(trimmedQuery) ?? []

            row = preservingSelection ? refreshedRow(from: searchResults, to: results, identifiedBy: \.application.bundlePath) : nil
            clipboardResults = []
            searchResults = results
        }

        if preservingSelection {
            reloadRefreshedResults(selecting: row)
            return
        }

        selectedRowIndex = getResultCount() == 0 ? -1 : 0
        reloadResults(animate: false)
        if !userHasOverriddenPinnedScrollSinceLastQueryChange {
            scrollResultsToTop(selectFirstRow: true)
        }

        // Update sidecar highlights (scroll-preserving) for clipboard mode
        if searchMode == .clipboard {
            refreshSidecarHighlightIfNeeded()
        }

        #if DEBUG
            let end = ProcessInfo.processInfo.systemUptime
            logger.debug("search(\(self.searchMode == .clipboard ? "clipboard" : "apps", privacy: .public)) took \((end - start) * 1000, privacy: .public)ms")
        #endif
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
            if let tableView {
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
        if let tableView {
            updateCardSelectionVisuals(tableView: tableView, previousRow: previousIndex, currentRow: selectedRowIndex)
        }
        updateSidecarVisibility()

        if searchMode == .clipboard {
            // Row numbers identify navigation without exposing the copied material.
            logger.debug("Selected clipboard history row \(self.selectedRowIndex, privacy: .public)")
        } else {
            print("Selected: \(selectedRowIndex) - \(searchResults[selectedRowIndex].application.name)")
        }
    }

    private func handleEnterKey() {
        if searchMode == .clipboard {
            guard selectedRowIndex >= 0, selectedRowIndex < clipboardResults.count else {
                hide()
                return
            }

            let item = clipboardResults[selectedRowIndex].item
            copyToClipboard(item.content)
        } else {
            guard selectedRowIndex >= 0, selectedRowIndex < searchResults.count else {
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
            if clickedRow >= 0, clickedRow < clipboardResults.count {
                let item = clipboardResults[clickedRow].item
                copyToClipboard(item.content)
            }
        } else {
            if clickedRow >= 0, clickedRow < searchResults.count {
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
            if let error {
                print("Error launching \(appInfo.name): \(error.localizedDescription)")
                // Handle error gracefully - could show alert here
                return
            }

            if let app {
                print("Successfully launched: \(app.localizedName ?? appInfo.name)")
            }

            self?.recentApplicationsStore.recordLaunch(bundlePath: bundlePath)

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
        let didWrite = pasteboard.setString(text, forType: .string)
        // Report the write outcome without retaining the clipboard payload in logs.
        logger.debug("Clipboard history replay write succeeded: \(didWrite, privacy: .public)")

        // Close the window after copying
        hide()

        // Auto-paste to frontmost app
        pasteToFrontmostApp()
    }

    /// Simulate Cmd+V to paste content
    private func pasteToFrontmostApp() {
        // Wait briefly for the window to hide and previous app to activate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            // kVK_ANSI_V is 0x09
            let vKeyCode: CGKeyCode = 0x09

            // Post key down with Command flag
            eventSource.postKeyboardEvent(keyCode: vKeyCode, keyDown: true, flags: .maskCommand)
            // Post key up with Command flag
            eventSource.postKeyboardEvent(keyCode: vKeyCode, keyDown: false, flags: .maskCommand)

            print("Simulated Cmd+V")
        }
    }

    func isVisible() -> Bool {
        isWindowVisible
    }

    // MARK: - Test Helpers

    /// Returns the current search mode (for testing)
    func getCurrentSearchMode() -> SearchMode {
        searchMode
    }

    /// Returns the current placeholder text (for testing)
    func getPlaceholderText() -> String? {
        searchField?.placeholderString
    }

    /// Returns the number of results currently displayed (for testing)
    func getResultCount() -> Int {
        searchMode == .clipboard ? clipboardResults.count : searchResults.count
    }

    /// Returns the current search text (for testing)
    func getSearchText() -> String? {
        searchField?.stringValue
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
        switch searchMode {
        case .clipboard:
            let matches = clipboardManager?.searchHistoryWithMatches(query: query) ?? []
            clipboardResults = matches.map { match in
                ClipboardSearchResult(item: match.item, relevanceScore: match.score, matchedIndices: match.matchedIndices)
            }
            searchResults = []
            selectedRowIndex = clipboardResults.isEmpty ? -1 : 0

        case .applications:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                updateApplicationResultsForEmptyQuery(animate: false)
                return
            }
            searchResults = searchService?.search(trimmed) ?? []
            clipboardResults = []
            selectedRowIndex = searchResults.isEmpty ? -1 : 0
        }

        reloadResults(animate: false)
        if !userHasOverriddenPinnedScrollSinceLastQueryChange {
            scrollResultsToTop(selectFirstRow: true)
        }
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
        searchMode = .applications
        searchResults = results
        selectedRowIndex = results.isEmpty ? -1 : 0
        tableView?.reloadData()
        if !results.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Sets clipboard results directly for snapshot testing
    func setClipboardResultsForTesting(_ items: [ClipboardItem]) {
        searchMode = .clipboard
        clipboardResults = items.map { ClipboardSearchResult(item: $0, relevanceScore: 0, matchedIndices: []) }
        selectedRowIndex = items.isEmpty ? -1 : 0
        searchField?.placeholderString = "Search clipboard history..."
        tableView?.reloadData()
        if !items.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Sets clipboard search results with matchedIndices for testing highlight behavior
    func setClipboardSearchResultsForTesting(_ results: [ClipboardSearchResult]) {
        searchMode = .clipboard
        clipboardResults = results
        selectedRowIndex = results.isEmpty ? -1 : 0
        searchField?.placeholderString = "Search clipboard history..."
        tableView?.reloadData()
        if !results.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSidecarVisibility()
    }

    /// Select a specific row for snapshot testing
    func selectRowForTesting(_ row: Int) {
        let count = searchMode == .clipboard ? clipboardResults.count : searchResults.count
        guard row >= 0, row < count else { return }
        selectedRowIndex = row
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
        selectedRowIndex
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
        searchMode == .clipboard ? clipboardResults.count : searchResults.count
    }
}

// MARK: - NSTableViewDelegate

extension WindowManager: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        // Display based on search mode
        if searchMode == .clipboard {
            makeClipboardCell(tableView: tableView, row: row)
        } else {
            makeApplicationCell(tableView: tableView, row: row)
        }
    }

    private func makeClipboardCell(tableView: NSTableView, row: Int) -> NSView? {
        guard row >= 0, row < clipboardResults.count else { return nil }

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

        let result = clipboardResults[row]
        let item = result.item

        // Collapse to single line: replace newlines/tabs with spaces, collapse multiple spaces
        let singleLine = item.content
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        let displayContent = singleLine.count > 100
            ? String(singleLine.prefix(100)) + "..."
            : singleLine

        // Remap matched indices from original content to collapsed single-line content
        // For simplicity, re-match on the display content to get correct indices
        let rematchedIndices: [Int]
        if !result.matchedIndices.isEmpty, let query = searchField?.stringValue, !query.isEmpty {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let rematch = FuzzyMatcher.matchWithIndices(query: trimmedQuery, candidate: displayContent)
            rematchedIndices = rematch.matchedIndices.filter { $0 < displayContent.count }
        } else {
            rematchedIndices = []
        }

        if let textField = cardContainer?.viewWithTag(200) as? NSTextField {
            textField.attributedStringValue = attributedString(
                for: displayContent,
                highlightingIndices: rematchedIndices,
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
        guard row >= 0, row < searchResults.count else { return nil }

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

        let result = searchResults[row]
        let appInfo = result.application

        // Get app icon
        if let imageView = cardContainer?.viewWithTag(100) as? NSImageView {
            let icon = iconCache.icon(forBundlePath: appInfo.bundlePath)
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

    func tableViewSelectionDidChange(_: Notification) {
        guard let tableView else { return }

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

    /// Creates an attributed string with matched characters highlighted using the system accent color.
    private func attributedString(for text: String, highlightingIndices indices: [Int], font: NSFont) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
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

/// NSWindowDelegate to handle window events
extension WindowManager: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Hide when main window loses focus (clicking outside)
        // But not when sidecar gains focus (it's part of our UI)
        guard notification.object as? NSWindow === window, sidecarWindow?.isKeyWindow != true else { return }
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
        // Ensure pending debounced searches don't run after hiding.
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil

        // When text exists, Esc should clear + hide.
        if let searchField, !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            lastSearchQuery = ""

            let previousSelection = selectedRowIndex
            selectedRowIndex = -1
            tableView?.deselectAll(nil)

            if let tableView {
                updateCardSelectionVisuals(tableView: tableView, previousRow: previousSelection, currentRow: -1)
            }
        }

        // Always hide on Esc.
        hide()
    }
}
