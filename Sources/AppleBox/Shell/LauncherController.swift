import AppKit
import OSLog
import SwiftUI

/// Presents the launcher panel and translates its keys into model intents, so the model stays free
/// of windows and the panel stays free of launcher logic.
final class LauncherController: NSObject, NSWindowDelegate {
    private let model: LauncherModel
    /// The panel this controller drives; internal so tests can feed it key events without a hotkey.
    let panel: LauncherPanel
    /// Records why the panel could not open, since a silent hotkey press is hard to diagnose.
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox",
        category: "launcher-shell"
    )

    /// Owned here, not by a view, so icons survive the panel being hidden and can be warmed before the
    /// first opening.
    private let iconCache: AppIconCache
    /// Shared by rows and the preview so each clip image is decoded once.
    private let imageCache = ClipboardImageCache()
    /// The pending order-out after the close motion; kept so a quick reopen can cancel it.
    private var closeTask: Task<Void, Never>?

    /// Whether the panel is on screen, for the hotkey toggle. A panel that is fading out counts as
    /// hidden, so a second hotkey press reopens it instead of closing it twice.
    var isVisible: Bool {
        panel.isVisible && closeTask == nil
    }

    init(model: LauncherModel, iconProvider: AppIconProviding = SystemAppIconProvider()) {
        self.model = model
        iconCache = AppIconCache(loader: iconProvider)
        panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: DesignTokens.Layout.appPanelSize))
        super.init()
        let host = NSHostingView(rootView: LauncherView(model: model)
            .environment(\.appIcons, iconCache)
            .environment(\.clipImages, imageCache))
        // The controller sizes the panel per mode; letting the content drive the window size would fight it.
        host.sizingOptions = []
        panel.contentView = host
        panel.setAccessibilityIdentifier(DesignTokens.Identifier.window)
        panel.delegate = self
        panel.keyHandler = { [weak self] key in self?.handle(key) ?? false }
        // Weak, because the model outlives a closed controller and must not keep it alive.
        model.onDismiss = { [weak self] in self?.hide() }
    }

    /// Hides when visible and the caller asks for the same list; switches list when asked for the other.
    func toggle(mode: SearchMode?) {
        guard isVisible else {
            show(mode: mode)
            return
        }
        if let mode, mode != model.mode {
            model.switchMode(to: mode)
            resizeAndPosition(on: panel.screen)
        } else {
            hide()
        }
    }

    /// Opens the panel. The model goes first because it records the paste target, which is whichever
    /// app has focus before the panel takes the keyboard.
    func show(mode: SearchMode?) {
        // A reopen during the close motion must not be undone by the pending order-out.
        closeTask?.cancel()
        closeTask = nil
        model.show(mode: mode)
        guard resizeAndPosition() else {
            // Without a screen there is nowhere to draw; undo the session so the model does not think
            // it is presented.
            model.hide()
            logger.error("show failed: no screen available, mode=\(String(describing: mode), privacy: .public)")
            return
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
    }

    /// Closes the panel and ends the session. A sheet is dismissed first, or it would be orphaned.
    func hide() {
        if let sheet = panel.attachedSheet {
            panel.endSheet(sheet, returnCode: .cancel)
        }
        model.hide()
        guard panel.isVisible, closeTask == nil else { return }
        // The model's close state drives the fade; the window must outlive it, or the motion is never seen.
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? DesignTokens.Motion.reducedFade
            : DesignTokens.Motion.closeDuration
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            closeTask = nil
            panel.orderOut(nil)
        }
    }

    /// Applies the app index once it exists; forwarded so the app delegate holds one launcher object.
    func setSearchService(_ service: SearchService) {
        model.setSearchService(service)
    }

    /// Applies the clipboard history once it has loaded.
    func setClipboardManager(_ manager: ClipboardManager) {
        model.setClipboardManager(manager)
    }

    /// Publishes the shortcut description for assistive technology on the search field.
    func setSearchShortcutHelp(_ help: String) {
        model.searchShortcutHelp = help
    }

    /// Loads icons ahead of the first search so the list never opens with placeholders.
    func prewarmAppIcons(applications: [ApplicationInfo]) {
        let bundlePaths = applications.map(\.bundlePath)
        DispatchQueue.global(qos: .utility).async { [iconCache] in
            iconCache.prewarm(bundlePaths: bundlePaths)
        }
    }

    /// Click-away dismissal. A sheet taking key status is part of the launcher, so it must not close it.
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel.attachedSheet == nil, closeTask == nil else { return }
        hide()
    }

    /// Runs a reserved key as a model intent. Copy reports whether there was something to copy, so
    /// the panel can let the key through when there was not.
    private func handle(_ key: LauncherKey) -> Bool {
        switch key {
        case .up: model.moveSelection(by: -1)
        case .down: model.moveSelection(by: 1)
        case .activate: model.activateSelection()
        case .copy: return model.copySelection()
        case .escape: model.escape()
        }
        return true
    }

    /// Sizes the panel for the current mode and puts it on the screen holding the mouse, centered
    /// horizontally with the top edge at the anchor. A mode switch passes the panel's current screen so the
    /// panel does not jump if the mouse moved meanwhile. Returns false when no screen exists.
    @discardableResult
    private func resizeAndPosition(on current: NSScreen? = nil) -> Bool {
        guard let screen = current ?? Self.activeScreen() else { return false }
        let size = model.mode == .clipboard
            ? DesignTokens.Layout.clipPanelSize
            : DesignTokens.Layout.appPanelSize
        let area = screen.visibleFrame
        // Screen coordinates grow upward, so the anchor is measured down from the top of the area.
        let topEdge = area.maxY - area.height * DesignTokens.Layout.verticalAnchor
        let origin = NSPoint(x: area.midX - size.width / 2, y: topEdge - size.height)
        // Clamp so a small screen or a low anchor never leaves part of the panel off screen.
        let clampedX = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        let clampedY = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        panel.setFrame(NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: size), display: true)
        return true
    }

    /// The screen under the mouse, because that is where the user is looking; the main screen is the
    /// fallback for a pointer between displays.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
