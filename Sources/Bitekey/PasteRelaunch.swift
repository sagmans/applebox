import AppKit
import OSLog

/// Menu bar action that restarts Bitekey after the user grants the paste permission. macOS checks
/// that permission when the app starts, so a running Bitekey keeps acting as if it were missing.
/// The item shows only while paste is unavailable, which is the only time a relaunch helps.
final class PasteRelaunchMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private enum Title {
        static let relaunch = "Relaunch to Enable Paste"
        /// Restart arrow in the toast's warning color, so the item matches the notice that sent the user here.
        static let attentionSymbol = "arrow.clockwise.circle.fill"
        static let failed = "Could Not Relaunch Bitekey"
        static let recovery = "Quit Bitekey from the menu bar, then open it again."
    }

    private let eventSource: EventSourceProtocol
    private let workspace: WorkspaceProtocol
    private let logger = Logger(subsystem: LogSubsystem.name, category: RelaunchHandoff.logCategory)
    /// Set while a new copy is starting. A second click in that window would start another copy, and
    /// both would pass the handoff once this one quits, leaving two instances, so the item is disabled.
    private var isRelaunching = false
    /// True while the badge and the highlighted item ask the user to grant paste and relaunch.
    /// Paste is the app's main action, so a missing permission is flagged from launch, not first use.
    private var needsAttention = false
    /// Lets the owner of the status item show or clear its badge; the menu does not own the button.
    var onAttentionChange: ((Bool) -> Void)?
    let item = NSMenuItem(title: Title.relaunch, action: #selector(relaunch), keyEquivalent: "")

    init(eventSource: EventSourceProtocol = SystemEventSource(), workspace: WorkspaceProtocol = SystemWorkspace()) {
        self.eventSource = eventSource
        self.workspace = workspace
        super.init()
        item.target = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteWasBlocked),
            name: ClipboardReplay.pastePermissionNeeded,
            object: nil
        )
        refresh()
    }

    /// Set as the status menu's delegate, because macOS may report the permission differently
    /// later in the process, so the item is checked again each time the menu opens.
    func menuNeedsUpdate(_: NSMenu) {
        refresh()
    }

    private func refresh() {
        let canPaste = eventSource.canPostPaste
        item.isHidden = canPaste
        // If macOS reports the grant without a relaunch, the badge would point at a hidden item.
        if canPaste, needsAttention {
            needsAttention = false
            item.image = nil
            item.attributedTitle = nil
            onAttentionChange?(false)
        }
    }

    /// Called once the status item exists, so the badge has a button to sit on. Asking at launch
    /// lists Bitekey in the permission pane before the first paste, so the user can grant it and
    /// relaunch before paste is needed.
    /// This is the only place that prompts, so the user sees the macOS prompt once per launch.
    func checkPermissionAtLaunch() {
        guard !eventSource.canPostPaste else { return }
        eventSource.requestPostAccess()
        requestAttention()
    }

    /// A backstop for the launch check: the paste path checks the permission again, and if it finds
    /// it missing after a launch check that passed, the menu must still point at the relaunch.
    @objc private func pasteWasBlocked() {
        requestAttention()
    }

    private func requestAttention() {
        guard !needsAttention else { return }
        needsAttention = true
        // Same color as the menu bar dot and the toast, so the eye goes from the dot straight to this item.
        let attention = NSColor(DesignTokens.Palette.warning)
        let symbol = NSImage(systemSymbolName: Title.attentionSymbol, accessibilityDescription: nil)
        item.image = symbol?.withSymbolConfiguration(.init(paletteColors: [attention]))
        // An attributed title drops the menu font unless it is set, so the item would stand out by size too.
        item.attributedTitle = NSAttributedString(
            string: Title.relaunch,
            attributes: [.foregroundColor: attention, .font: NSFont.menuFont(ofSize: 0)]
        )
        onAttentionChange?(true)
    }

    /// The status menu enables items automatically, so this is where the item turns off during a relaunch.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== item || !isRelaunching
    }

    @objc private func relaunch() {
        guard !isRelaunching else { return }
        isRelaunching = true
        refresh()

        let configuration = NSWorkspace.OpenConfiguration()
        // A second instance is required: asking LaunchServices for the running app would only activate it.
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = [RelaunchHandoff.argument, String(ProcessInfo.processInfo.processIdentifier)]
        let bundleURL = Bundle.main.bundleURL
        workspace.openApplication(at: bundleURL, configuration: configuration) { [weak self] launched, error in
            // Reduced to Sendable values here, so the running-app object never crosses to the main actor.
            let started = launched != nil && error == nil
            let failure = error.map { $0 as NSError }
            // Quit only after the new copy is running, so a failed launch leaves the user with a working app.
            Task { @MainActor in
                guard started else {
                    self?.reportFailure(bundleURL: bundleURL, domain: failure?.domain, code: failure?.code)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func reportFailure(bundleURL: URL, domain: String?, code: Int?) {
        isRelaunching = false
        refresh()
        logger.error("Relaunch failed: bundle=\(bundleURL.path, privacy: .public) error=\(domain ?? "none", privacy: .public)/\(code ?? 0, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = Title.failed
        alert.informativeText = Title.recovery
        NSApp.activate()
        alert.runModal()
    }
}
