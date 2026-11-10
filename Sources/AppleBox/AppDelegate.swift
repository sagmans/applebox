import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: HotkeyManager?
    private var windowManager: WindowManager?
    private var appIndexer: ApplicationIndexer?
    private var clipboardManager: ClipboardManager?

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

        // Warm icons as soon as the index is ready.
        appIndexer.scanForApplicationsAsync { [weak windowManager] apps in
            windowManager?.prewarmAppIcons(applications: apps)
        }

        // Initialize hotkey manager.
        hotkeyManager = HotkeyManager { [weak self] mode in
            let searchMode: SearchMode = mode == .clipboard ? .clipboard : .applications
            self?.toggleWindow(mode: searchMode)
        }

        hotkeyManager?.start()
    }

    func applicationWillTerminate(_: Notification) {
        logger.info("AppleBox terminating")
        clipboardManager?.flushPendingPersistence()
    }

    private func toggleWindow(mode: SearchMode? = nil) {
        windowManager?.toggle(mode: mode)
    }
}
