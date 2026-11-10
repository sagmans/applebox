import AppKit

/// The launcher keys the shell reserves. A closed set lets the controller map each one to a model
/// intent without knowing anything about raw key codes.
enum LauncherKey: Equatable {
    case up
    case down
    case activate
    case copy
    case escape
}

/// Hardware key codes the panel reserves; the same codes the legacy window routes.
private enum LauncherKeyCode {
    static let escape: UInt16 = 53
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let returnKey: UInt16 = 36
}

/// A borderless, non-activating panel for the launcher.
///
/// Non-activating, so opening it does not pull AppleBox to the front of the other apps, which keeps
/// the app that will receive a paste focused. It can still become key, so the search field takes typing.
final class LauncherPanel: NSPanel {
    /// Set by the controller. Returning false lets the event continue to the responder chain, so a key
    /// the shell declines still behaves as it would in any window.
    var keyHandler: ((LauncherKey) -> Bool)?

    /// Required so the search field can take focus even though the panel never activates the app.
    override var canBecomeKey: Bool {
        true
    }

    /// The launcher is not a document window, so it must never take over the main-window role.
    override var canBecomeMain: Bool {
        false
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        // Floating, on every Space and over full-screen apps, so the launcher appears wherever the user is.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The SwiftUI glass draws its own background and shadow shape; an opaque window would show a box.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The controller owns the lifetime; a released-on-close panel would dangle behind it.
        isReleasedWhenClosed = false
    }

    /// Maps an event to a reserved key, or nil when the panel should leave it alone. Plain Return and
    /// Option-Return are told apart here because the search field would otherwise consume both as a
    /// text command before any handler saw them.
    static func launcherKey(for event: NSEvent) -> LauncherKey? {
        guard event.type == .keyDown else { return nil }
        switch event.keyCode {
        case LauncherKeyCode.escape: return .escape
        case LauncherKeyCode.upArrow: return .up
        case LauncherKeyCode.downArrow: return .down
        case LauncherKeyCode.returnKey:
            let isCopyChord = event.charactersIgnoringModifiers == CopyClipShortcut.key
                && event.modifierFlags.intersection(CopyClipShortcut.relevantModifiers) == CopyClipShortcut.modifiers
            return isCopyChord ? .copy : .activate
        default: return nil
        }
    }

    /// Intercepts reserved keys before the field editor sees them. Skipped during IME composition,
    /// because those keys then confirm or cancel the composed text and must reach the input method.
    override func sendEvent(_ event: NSEvent) {
        if (firstResponder as? NSTextView)?.hasMarkedText() != true,
           let key = Self.launcherKey(for: event),
           keyHandler?(key) == true
        {
            return
        }
        super.sendEvent(event)
    }

    /// Esc can arrive as a command from a control that swallowed the key event, so it is routed too.
    override func cancelOperation(_ sender: Any?) {
        if keyHandler?(.escape) != true {
            super.cancelOperation(sender)
        }
    }
}
