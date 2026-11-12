import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Menu bar artwork drawn from the Bitekey logo, so the status item reads as
    /// this app instead of a generic placeholder glyph.
    private enum StatusIcon {
        /// Base name of the bundled PNGs; AppKit picks the @2x file on Retina screens.
        static let resourceName = "MenuBarIconTemplate"
        /// Apple's menu bar extra guideline height. Pinned so replacement artwork drawn
        /// at another pixel size still fills the same slot as the system icons.
        static let pointSize = NSSize(width: 18, height: 18)
        /// SF Symbol used when the logo is not bundled, such as in `swift run` builds.
        static let fallbackSymbol = "square.grid.2x2"
    }

    private static let migrationLogCategory = "migration"

    /// Names the migration steps in the log so a filter can pick one.
    private enum MigrationStep: String {
        case staleTemps, folder, preferences
    }

    private enum MenuTitle {
        static let app = "Bitekey"
        /// Spoken and shown on hover while the badge is up, since the dot alone carries no words.
        static let appNeedsRelaunch = "Bitekey – relaunch to enable paste"
        static let search = "Search Applications"
        static let clipboard = "Clipboard History"
        static let shortcuts = "Global Shortcuts"
        static let retry = "Retry Global Shortcuts"
        static let quit = "Quit Bitekey"
        static let unavailable = "Shortcut Unavailable"
        static let unavailableHelp = "Choose another shortcut. Bitekey kept any working shortcut for this mode."
        static let noActiveShortcut = "No active shortcut. Use the menu bar to open this mode."
        static let searchHelp = "Type to search applications or clipboard history."
    }

    private var hotkeyManager: HotkeyManager?
    private var launcher: LauncherController?
    private var appIndexer: ApplicationIndexer?
    private var clipboardManager: ClipboardManager?
    private var statusItem: NSStatusItem?
    private let loginItemMenu = LoginItemMenu()
    private let pasteRelaunch = PasteRelaunchMenu()
    private let statusBadge = StatusBadgeView()

    private let logger = Logger(
        subsystem: LogSubsystem.name,
        category: "app"
    )

    func applicationDidFinishLaunching(_: Notification) {
        logger.info("Bitekey launched")
        // A relaunch starts this copy before the old one quits; setup waits so only one instance owns
        // the shortcuts and history files.
        Task {
            switch await RelaunchHandoff.waitForPreviousInstance(arguments: CommandLine.arguments) {
            case .ready: startServices()
            case .previousStillRunning: NSApp.terminate(nil)
            }
        }
    }

    /// Logs step results only, never contents or preference values. The free-text cause may hold
    /// paths, so it stays private; the domain and code are stable and safe to share.
    private func logMigration(_ report: LegacyDataMigration.Report) {
        let logger = Logger(subsystem: LogSubsystem.name, category: Self.migrationLogCategory)
        let steps: [(MigrationStep, LegacyDataMigration.StepResult)] = [
            (.staleTemps, report.staleTemps), (.folder, report.folder), (.preferences, report.preferences),
        ]
        for (step, result) in steps {
            if case let .failed(failure) = result {
                logger.error("Legacy migration step failed: step=\(step.rawValue, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public) cause=\(failure.detail, privacy: .private)")
            } else {
                logger.debug("Legacy migration step finished: step=\(step.rawValue, privacy: .public) result=\(String(describing: result), privacy: .public)")
            }
        }
    }

    private func startServices() {
        // Before any store loads, so none reads the new, still empty location first.
        logMigration(LegacyDataMigration().run())

        // UI first: show/typing must never wait on indexing/persistence.
        // The model owns launcher state; the controller presents it and forwards input.
        let launcherModel = LauncherModel()
        let launcher = LauncherController(model: launcherModel)
        self.launcher = launcher

        // Start indexing asynchronously.
        let appIndexer = ApplicationIndexer(scanSynchronously: false)
        self.appIndexer = appIndexer
        let searchService = SearchService(indexer: appIndexer)
        launcher.setSearchService(searchService)

        // Load clipboard history asynchronously and start monitoring.
        let clipboardManager = ClipboardManager(capturePreferences: .standard, loadSynchronously: false)
        self.clipboardManager = clipboardManager
        launcher.setClipboardManager(clipboardManager)

        // Start watching before the scan so an install during startup queues a refresh.
        appIndexer.startMonitoring()
        appIndexer.scanForApplicationsAsync { [weak launcher] apps in
            launcher?.prewarmAppIcons(applications: apps)
        }

        // Initialize hotkey manager.
        hotkeyManager = HotkeyManager { [weak self] mode in
            let searchMode: SearchMode = mode == .clipboard ? .clipboard : .applications
            self?.toggleWindow(mode: searchMode)
        }

        // The menu must be available even if macOS rejects every global shortcut.
        installStatusMenu()
        hotkeyManager?.start()
        refreshShortcutMenu()
    }

    func applicationWillTerminate(_: Notification) {
        logger.info("Bitekey terminating")
        hotkeyManager?.stop()
        clipboardManager?.flushPendingPersistence()
        launcher?.flushPendingPersistence()
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let icon = statusIconImage() {
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
        menu.addItem(pasteRelaunch.item)
        // The relaunch item depends on a permission the user changes outside the app.
        menu.delegate = pasteRelaunch
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: MenuTitle.shortcuts, action: nil, keyEquivalent: ""))
        addStatusAction(to: menu, title: MenuTitle.retry, action: #selector(retryShortcutsFromMenu))
        menu.addItem(.separator())
        menu.addItem(loginItemMenu.item)
        addStatusAction(to: menu, title: MenuTitle.quit, action: #selector(quitFromMenu))
        item.menu = menu
        statusItem = item
        pasteRelaunch.onAttentionChange = { [weak self] needed in self?.showStatusBadge(needed) }
        pasteRelaunch.checkPermissionAtLaunch()
    }

    /// Keeps the pending relaunch visible after the paste toast fades. A relaunch starts a fresh
    /// process, so the badge clears by itself once paste works.
    private func showStatusBadge(_ visible: Bool) {
        guard let button = statusItem?.button else { return }
        if visible, statusBadge.superview == nil {
            statusBadge.attach(to: button)
        } else if !visible {
            statusBadge.removeFromSuperview()
        }
        button.setAccessibilityLabel(visible ? MenuTitle.appNeedsRelaunch : MenuTitle.app)
        button.toolTip = visible ? MenuTitle.appNeedsRelaunch : MenuTitle.app
    }

    /// Prefers the bundled logo artwork and falls back to an SF Symbol, so the menu
    /// stays reachable even when the bundle lacks the image.
    private func statusIconImage() -> NSImage? {
        guard let logo = Bundle.main.image(forResource: StatusIcon.resourceName) else {
            // Notice, not error: unbundled dev builds reach this path on purpose.
            logger.notice("Status icon not bundled, using fallback: \(StatusIcon.resourceName, privacy: .public)")
            let symbol = NSImage(systemSymbolName: StatusIcon.fallbackSymbol, accessibilityDescription: MenuTitle.app)
            symbol?.isTemplate = true
            return symbol
        }
        logo.size = StatusIcon.pointSize
        // Template mode lets AppKit tint the artwork for light, dark and highlighted states.
        logo.isTemplate = true
        logo.accessibilityDescription = MenuTitle.app
        return logo
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
        DispatchQueue.main.async { [weak self] in self?.launcher?.show(mode: mode) }
    }

    @objc private func retryShortcutsFromMenu() {
        hotkeyManager?.start()
        refreshShortcutMenu()
    }

    private struct ShortcutChoice {
        let mode: HotkeyMode
        let preset: HotkeyPreset
    }

    private func refreshShortcutMenu() {
        guard let hotkeyManager, let item = statusItem?.menu?.item(withTitle: MenuTitle.shortcuts) else { return }
        let menu = NSMenu(title: MenuTitle.shortcuts)
        for mode in HotkeyMode.allCases {
            let title = mode == .application ? MenuTitle.search : MenuTitle.clipboard
            let modeItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            modeItem.submenu = shortcutOptions(for: mode, title: title, manager: hotkeyManager)
            menu.addItem(modeItem)
        }
        item.submenu = menu

        let search = hotkeyManager.activePreset(for: .application)?.chord.label ?? MenuTitle.noActiveShortcut
        let clipboard = hotkeyManager.activePreset(for: .clipboard)?.chord.label ?? MenuTitle.noActiveShortcut
        launcher?.setSearchShortcutHelp("\(MenuTitle.searchHelp) \(MenuTitle.search) \(search). \(MenuTitle.clipboard) \(clipboard).")
    }

    private func shortcutOptions(for mode: HotkeyMode, title: String, manager: HotkeyManager) -> NSMenu {
        let menu = NSMenu(title: title)
        let preferred = manager.preferredPreset(for: mode)
        let active = manager.activePreset(for: mode)
        if active != preferred {
            menu.addItem(NSMenuItem(title: "\(preferred.chord.label) unavailable", action: nil, keyEquivalent: ""))
        }
        if active == nil {
            menu.addItem(NSMenuItem(title: MenuTitle.noActiveShortcut, action: nil, keyEquivalent: ""))
        }
        for preset in HotkeyPreset.allCases {
            let option = NSMenuItem(title: preset.chord.label, action: #selector(chooseShortcutFromMenu(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = ShortcutChoice(mode: mode, preset: preset)
            option.state = preset == active ? .on : .off
            menu.addItem(option)
        }
        return menu
    }

    @objc private func chooseShortcutFromMenu(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? ShortcutChoice, let hotkeyManager else { return }
        let chosen = hotkeyManager.choose(choice.preset, for: choice.mode)
        refreshShortcutMenu()
        guard !chosen else { return }

        // Present the conflict only after AppKit releases the menu's event tracking.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(MenuTitle.unavailable) — \(choice.preset.chord.label)"
            alert.informativeText = MenuTitle.unavailableHelp
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func toggleWindow(mode: SearchMode? = nil) {
        if mode != .clipboard {
            appIndexer?.refreshIfMonitoringUnavailable()
        }
        launcher?.toggle(mode: mode)
    }
}
