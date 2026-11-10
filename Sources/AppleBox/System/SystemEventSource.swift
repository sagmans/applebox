import Carbon.HIToolbox
import CoreGraphics

/// Production implementation of EventSourceProtocol wrapping CGEventSource
public final class SystemEventSource: EventSourceProtocol {
    private let source: CGEventSource?
    private let pasteKey = CGKeyCode(kVK_ANSI_V)

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    public var canPostPaste: Bool {
        CGPreflightPostEventAccess()
    }

    public func requestPostAccess() {
        // The answer is not needed: the next paste preflights again, and the prompt is the point.
        _ = CGRequestPostEventAccess()
    }

    public func postPaste(to process: pid_t) -> Bool {
        // Prepare the pair before sending either event to the verified process.
        guard process > 0, let source,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(process)
        keyUp.postToPid(process)
        return true
    }
}
