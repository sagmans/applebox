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

    /// Whether the panel is on screen, for the hotkey toggle.
    var isVisible: Bool {
        panel.isVisible
    }

    init(model: LauncherModel) {
        self.model = model
        panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: DesignTokens.Layout.appPanelSize))
        super.init()
        // The views arrive in a later step; an empty host keeps the panel's content view in place.
        panel.contentView = NSHostingView(rootView: EmptyView())
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
        panel.orderOut(nil)
    }

    /// Click-away dismissal. A sheet taking key status is part of the launcher, so it must not close it.
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel.attachedSheet == nil else { return }
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
