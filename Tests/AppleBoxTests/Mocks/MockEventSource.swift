import CoreGraphics
@testable import AppleBox

/// Mock implementation of EventSourceProtocol for testing
final class MockEventSource: EventSourceProtocol {
    // MARK: - Invocation Tracking

    /// Recorded keyboard event
    struct KeyboardEvent {
        let keyCode: CGKeyCode
        let keyDown: Bool
        let flags: CGEventFlags
    }

    /// Tracks all posted keyboard events
    var postedKeyboardEvents: [KeyboardEvent] = []

    // MARK: - EventSourceProtocol Implementation

    func postKeyboardEvent(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        let event = KeyboardEvent(
            keyCode: keyCode,
            keyDown: keyDown,
            flags: flags
        )
        postedKeyboardEvents.append(event)
    }

    // MARK: - Helper Methods

    /// Clears all recorded invocations
    func resetInvocations() {
        postedKeyboardEvents = []
    }

    /// Returns the number of keyboard events posted
    var keyboardEventCount: Int {
        return postedKeyboardEvents.count
    }

    /// Returns the last keyboard event posted
    var lastKeyboardEvent: KeyboardEvent? {
        return postedKeyboardEvents.last
    }

    /// Returns all key down events
    var keyDownEvents: [KeyboardEvent] {
        return postedKeyboardEvents.filter { $0.keyDown }
    }

    /// Returns all key up events
    var keyUpEvents: [KeyboardEvent] {
        return postedKeyboardEvents.filter { !$0.keyDown }
    }

    /// Checks if a specific key sequence was posted (key down followed by key up)
    func wasKeyPressed(keyCode: CGKeyCode, withFlags flags: CGEventFlags) -> Bool {
        let hasKeyDown = postedKeyboardEvents.contains { 
            $0.keyCode == keyCode && $0.keyDown && $0.flags == flags 
        }
        let hasKeyUp = postedKeyboardEvents.contains { 
            $0.keyCode == keyCode && !$0.keyDown && $0.flags == flags 
        }
        return hasKeyDown && hasKeyUp
    }
}
