import AppKit
import OSLog
import ServiceManagement

/// Use macOS as the source of truth so changes in System Settings appear in the menu.
final class LoginItemMenu: NSObject, NSMenuDelegate {
    private enum Title {
        static let menu = "Launch at Login"
        static let toggle = "Start AppleBox Automatically"
        static let pending = "Start AppleBox Automatically (Approval Required)"
        static let settings = "Open Login Items Settings"
        static let failed = "Could Not Change Launch at Login"
        static let recovery = "You can manage AppleBox under Open at Login in System Settings."
        static let dismiss = "OK"
    }

    private let service = SMAppService.mainApp
    private let toggle = NSMenuItem(title: Title.toggle, action: #selector(toggleLoginItem), keyEquivalent: "")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox", category: "login-item")
    let item = NSMenuItem(title: Title.menu, action: nil, keyEquivalent: "")

    override init() {
        super.init()
        let menu = NSMenu(title: Title.menu)
        menu.delegate = self
        toggle.target = self
        menu.addItem(toggle)
        let settings = NSMenuItem(title: Title.settings, action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        item.submenu = menu
        refresh()
    }

    func menuNeedsUpdate(_: NSMenu) {
        refresh()
    }

    private func refresh() {
        let status = service.status
        toggle.title = status == .requiresApproval ? Title.pending : Title.toggle
        toggle.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
    }

    @objc private func toggleLoginItem() {
        let status = service.status
        do {
            if status == .enabled || status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let failure = error as NSError
            logger.error("Could not change login item at status \(status.rawValue, privacy: .public): \(failure.domain, privacy: .public)/\(failure.code, privacy: .public)")
            // Wait for menu tracking to finish before showing the recovery action.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = Title.failed
                alert.informativeText = Title.recovery
                alert.addButton(withTitle: Title.settings)
                alert.addButton(withTitle: Title.dismiss)
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        refresh()
    }

    @objc private func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
