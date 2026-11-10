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

/// Hardware key codes the panel reserves, so a focused text field cannot consume these keys first.
/// Internal, not private, so tests post the same codes the panel matches instead of keeping copies.
enum LauncherKeyCode {
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

    /// Set by the controller during the close fade. Only reserved keys reach the key handler, so ordinary
    /// typing must be dropped here, or it would start a search in a field the user can no longer see.
    var dropsKeyEvents = false

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
        // The panel never activates the app, so a deactivate-hide would hide it while the model still
        // thinks it is presented; dismissal is owned by the controller.
        hidesOnDeactivate = false
        // The controller owns the lifetime; a released-on-close panel would dangle behind it.
        isReleasedWhenClosed = false
    }

    /// Maps an event to a reserved key, or nil when the panel should leave it alone. Only the plain keys
    /// and the copy chord are reserved: Shift, Command or Control combinations belong to the search
    /// field, and a stray modifier must never turn a copy into a paste. Function and numeric-pad flags
    /// are ignored because arrow events always carry them.
    static func launcherKey(for event: NSEvent) -> LauncherKey? {
        guard event.type == .keyDown else { return nil }
        let held = event.modifierFlags.intersection(CopyClipShortcut.relevantModifiers)
        switch event.keyCode {
        case LauncherKeyCode.escape: return .escape
        case LauncherKeyCode.upArrow: return held.isEmpty ? .up : nil
        case LauncherKeyCode.downArrow: return held.isEmpty ? .down : nil
        case LauncherKeyCode.returnKey:
            if held.isEmpty {
                return .activate
            }
            let isCopyChord = event.charactersIgnoringModifiers == CopyClipShortcut.key
                && held == CopyClipShortcut.modifiers
            return isCopyChord ? .copy : nil
        default: return nil
        }
    }

    /// Whether a reserved key belongs to the launcher given where the keyboard focus is. A text view that
    /// is not the search field's editor, such as the selectable preview, needs arrows and Return for
    /// its own text navigation, so they pass through to it. Esc closes the launcher from anywhere.
    static func routes(_ key: LauncherKey, firstResponder: NSResponder?) -> Bool {
        if key == .escape {
            return true
        }
        guard let textView = firstResponder as? NSTextView else { return true }
        return textView.isFieldEditor
    }

    /// Intercepts reserved keys before the field editor sees them. Skipped during IME composition,
    /// because those keys then confirm or cancel the composed text and must reach the input method.
    override func sendEvent(_ event: NSEvent) {
        if dropsKeyEvents, event.type == .keyDown || event.type == .keyUp {
            return
        }
        if (firstResponder as? NSTextView)?.hasMarkedText() != true,
           let key = Self.launcherKey(for: event),
           Self.routes(key, firstResponder: firstResponder),
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
