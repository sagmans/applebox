import CoreGraphics

/// Production implementation of EventSourceProtocol wrapping CGEventSource
public final class SystemEventSource: EventSourceProtocol {
    private let source: CGEventSource?

    public init() {
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    public func postKeyboardEvent(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        guard let source = source else { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
