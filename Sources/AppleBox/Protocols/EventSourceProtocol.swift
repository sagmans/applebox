import CoreGraphics

/// Protocol abstracting CGEventSource and CGEvent posting for testability
public protocol EventSourceProtocol {
    /// Posts a keyboard event with the specified parameters
    /// - Parameters:
    ///   - keyCode: The virtual key code of the key to simulate
    ///   - keyDown: Whether this is a key down (true) or key up (false) event
    ///   - flags: The modifier flags (e.g., Command, Shift, etc.)
    func postKeyboardEvent(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags)
}
