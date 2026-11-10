import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum MenuTitle {
        static let app = "AppleBox"
        static let icon = "square.grid.2x2"
        static let search = "Search Applications"
        static let clipboard = "Clipboard History"
        static let retry = "Retry Global Shortcuts"
        static let quit = "Quit AppleBox"
    }

    private var hotkeyManager: HotkeyManager?
    private var windowManager: WindowManager?
    private var appIndexer: ApplicationIndexer?
    private var clipboardManager: ClipboardManager?
    private var statusItem: NSStatusItem?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox",
        category: "app"
    )

    func applicationDidFinishLaunching(_: Notification) {
        logger.info("AppleBox launched")

        // UI first: show/typing must never wait on indexing/persistence.
        let windowManager = WindowManager()
        self.windowManager = windowManager

        // Start indexing asynchronously.
        let appIndexer = ApplicationIndexer(scanSynchronously: false)
        self.appIndexer = appIndexer
        let searchService = SearchService(indexer: appIndexer)
        windowManager.setSearchService(searchService)

        // Load clipboard history asynchronously and start monitoring.
        let clipboardManager = ClipboardManager(capturePreferences: .standard, loadSynchronously: false)
        self.clipboardManager = clipboardManager
        windowManager.setClipboardManager(clipboardManager)

        // Start watching before the scan so an install during startup queues a refresh.
        appIndexer.startMonitoring()
        appIndexer.scanForApplicationsAsync { [weak windowManager] apps in
            windowManager?.prewarmAppIcons(applications: apps)
        }

        // Initialize hotkey manager.
        hotkeyManager = HotkeyManager { [weak self] mode in
            let searchMode: SearchMode = mode == .clipboard ? .clipboard : .applications
            self?.toggleWindow(mode: searchMode)
        }

        // The menu must be available even if macOS rejects every global shortcut.
        installStatusMenu()
        hotkeyManager?.start()
    }

    func applicationWillTerminate(_: Notification) {
        logger.info("AppleBox terminating")
        hotkeyManager?.stop()
        clipboardManager?.flushPendingPersistence()
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let icon = NSImage(systemSymbolName: MenuTitle.icon, accessibilityDescription: MenuTitle.app) {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.title = MenuTitle.app
            }
            button.setAccessibilityLabel(MenuTitle.app)
            button.toolTip = MenuTitle.app
        }

        let menu = NSMenu(title: MenuTitle.app)
        addStatusAction(to: menu, title: MenuTitle.search, action: #selector(openAppSearchFromMenu))
        addStatusAction(to: menu, title: MenuTitle.clipboard, action: #selector(openClipboardFromMenu))
        menu.addItem(.separator())
        addStatusAction(to: menu, title: MenuTitle.retry, action: #selector(retryShortcutsFromMenu))
        menu.addItem(.separator())
        addStatusAction(to: menu, title: MenuTitle.quit, action: #selector(quitFromMenu))
        item.menu = menu
        statusItem = item
    }

    private func addStatusAction(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openAppSearchFromMenu() {
        appIndexer?.refreshIfMonitoringUnavailable()
        openFromMenu(mode: .applications)
    }

    @objc private func openClipboardFromMenu() {
        openFromMenu(mode: .clipboard)
    }

    private func openFromMenu(mode: SearchMode) {
        // Let AppKit finish tracking the menu before the launcher takes keyboard focus.
        DispatchQueue.main.async { [weak self] in self?.windowManager?.show(mode: mode) }
    }

    @objc private func retryShortcutsFromMenu() {
        hotkeyManager?.start()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func toggleWindow(mode: SearchMode? = nil) {
        if mode != .clipboard {
            appIndexer?.refreshIfMonitoringUnavailable()
        }
        windowManager?.toggle(mode: mode)
    }
}
