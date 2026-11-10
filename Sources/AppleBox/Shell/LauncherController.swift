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
        subsystem: LogSubsystem.name,
        category: "launcher-shell"
    )

    /// Owned here, not by a view, so icons survive the panel being hidden and can be warmed before the
    /// first opening.
    private let iconCache: AppIconCache
    /// Shared by rows and the preview so each clip image is decoded once.
    private let imageCache = ClipboardImageCache()
    /// The pending order-out after the close motion; kept so a quick reopen can cancel it.
    private var closeTask: Task<Void, Never>?
    /// The pending shrink after a mode morph; kept so another switch, a hide or a reopen can cancel it.
    private var resizeTask: Task<Void, Never>?
    /// Watches the clear-history sheet, which takes key status from the panel while it is up.
    private var sheetObserver: NSObjectProtocol?

    /// Whether a launcher session is open, for the hotkey toggle. The model is the only source: it turns
    /// false the moment `hide()` runs, so a panel that is fading out counts as hidden and a second hotkey
    /// press reopens it instead of closing it twice. Reading the window as well would let the two drift.
    var isVisible: Bool {
        model.isPresented
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
        panel.setAccessibilityLabel(DesignTokens.Copy.windowLabel)
        panel.setAccessibilityHelp(DesignTokens.Copy.windowHelp)
        panel.delegate = self
        panel.keyHandler = { [weak self] key in self?.handle(key) ?? false }
        // Weak, because the model outlives a closed controller and must not keep it alive.
        model.onDismiss = { [weak self] in self?.hide() }
        observeSheetFocus()
    }

    /// Isolated so teardown can read the main-actor observer.
    isolated deinit {
        if let sheetObserver {
            NotificationCenter.default.removeObserver(sheetObserver)
        }
    }

    /// Hides when visible and the caller asks for the same list; switches list when asked for the other.
    func toggle(mode: SearchMode?) {
        guard isVisible else {
            show(mode: mode)
            return
        }
        if let mode, mode != model.mode {
            model.switchMode(to: mode)
            resizeAfterModeSwitch()
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
        cancelPendingResize()
        panel.ignoresMouseEvents = false
        panel.dropsKeyEvents = false
        model.show(mode: mode)
        guard resizeAndPosition() else {
            // Without a screen there is nowhere to draw. Take the normal close path, not just the model's:
            // a panel still fading out from the last session is key, and would stay on screen orphaned.
            logger.error("show failed: no screen available, mode=\(String(describing: mode), privacy: .public)")
            hide()
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
        cancelPendingResize()
        model.hide()
        guard panel.isVisible, closeTask == nil else { return }
        // The model's close state drives the fade; the window must outlive it, or the motion is never seen.
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? DesignTokens.Motion.reducedFade
            : DesignTokens.Motion.closeDuration
        // The fade keeps the panel key, so without this a second Return would replay the clip and typing
        // would start a search in a hidden field. Keys are swallowed in `handle`; clicks are dropped here.
        panel.ignoresMouseEvents = true
        panel.dropsKeyEvents = true
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
        guard notification.object as? NSWindow === panel, panel.attachedSheet == nil, model.isPresented else { return }
        hide()
    }

    /// Closes the launcher when the user leaves it while the clear-history sheet is up. Click-away is
    /// ignored for the panel while a sheet is attached, because the sheet takes key from the panel; but
    /// when the user then clicks another app only the sheet resigns, and the panel with its clip preview
    /// would stay on screen over that app.
    private func observeSheetFocus() {
        // Delivered on the main queue, which the compiler cannot see through the Sendable block.
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { self?.sheetDidResignKey(window) }
        }
    }

    private func sheetDidResignKey(_ window: NSWindow?) {
        guard let window, window.sheetParent === panel, model.isPresented else { return }
        // Key status moves after this notification, and a sheet that is closing normally also resigns;
        // decide once it has landed, and only while the sheet is still up with nothing of ours key.
        DispatchQueue.main.async { [weak self] in
            guard let self, model.isPresented, let sheet = panel.attachedSheet,
                  !sheet.isKeyWindow, !panel.isKeyWindow else { return }
            hide()
        }
    }

    /// Runs a reserved key as a model intent. Copy reports whether there was something to copy, so
    /// the panel can let the key through when there was not.
    private func handle(_ key: LauncherKey) -> Bool {
        // Inert once the session is over, which includes the close fade: no key may act on it. Swallowing
        // (true) also stops typed characters from reaching the field.
        if !model.isPresented {
            return true
        }
        switch key {
        case .up: model.moveSelection(by: -1)
        case .down: model.moveSelection(by: 1)
        case .activate: model.activateSelection()
        case .copy: return model.copySelection()
        case .escape: model.escape()
        }
        return true
    }

    /// Grows the panel at once but shrinks it only after the mode morph settles. The glass body springs to
    /// its new width inside the panel, so shrinking the window first would cut off the body while it is
    /// still wider than the window. The content is centered in the panel, so the wait shows no jump.
    private func resizeAfterModeSwitch() {
        cancelPendingResize()
        let target = Self.panelSize(for: model.mode)
        guard target.width < panel.frame.width || target.height < panel.frame.height else {
            resizeAndPosition(on: panel.screen)
            return
        }
        let settle = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? DesignTokens.Motion.reducedFade
            : DesignTokens.Motion.openSpring.settlingDuration
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(settle))
            guard let self, !Task.isCancelled, model.isPresented else { return }
            resizeTask = nil
            resizeAndPosition(on: panel.screen)
        }
    }

    private func cancelPendingResize() {
        resizeTask?.cancel()
        resizeTask = nil
    }

    private static func panelSize(for mode: SearchMode) -> CGSize {
        mode == .clipboard ? DesignTokens.Layout.clipPanelSize : DesignTokens.Layout.appPanelSize
    }

    /// Sizes the panel for the current mode and puts it on the screen holding the mouse, centered
    /// horizontally with the top edge at the anchor. A mode switch passes the panel's current screen so the
    /// panel does not jump if the mouse moved meanwhile. Returns false when no screen exists.
    @discardableResult
    private func resizeAndPosition(on current: NSScreen? = nil) -> Bool {
        guard let screen = current ?? Self.activeScreen() else { return false }
        let size = Self.panelSize(for: model.mode)
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
