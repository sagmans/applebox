import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: HotkeyManager?
    private var windowManager: WindowManager?
    private var appIndexer: ApplicationIndexer?
    private var clipboardManager: ClipboardManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("AppleBox launched")

        // Initialize application indexer (runs scan on init)
        appIndexer = ApplicationIndexer()

        // Initialize search service
        let searchService = SearchService(indexer: appIndexer!)

        // Initialize clipboard manager (starts monitoring on init)
        clipboardManager = ClipboardManager()

        // Initialize window manager
        windowManager = WindowManager()
        windowManager?.setSearchService(searchService)
        windowManager?.setClipboardManager(clipboardManager!)

        // Initialize hotkey manager
        hotkeyManager = HotkeyManager { [weak self] mode in
            let searchMode: SearchMode = mode == .clipboard ? .clipboard : .applications
            self?.toggleWindow(mode: searchMode)
        }

        // Start monitoring hotkey
        hotkeyManager?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("AppleBox terminating")
    }

    private func toggleWindow(mode: SearchMode? = nil) {
        windowManager?.toggle(mode: mode)
    }
}
