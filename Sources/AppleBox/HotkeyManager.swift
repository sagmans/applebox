import AppKit

class HotkeyManager {
    private var eventMonitor: EventMonitor?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func start() {
        // Monitor for global key down events
        eventMonitor = EventMonitor(mask: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        eventMonitor?.start()
    }

    func stop() {
        eventMonitor?.stop()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Check for Cmd+Space
        // Cmd key is .command (0x100000), Space is character code 32
        let cmdPressed = event.modifierFlags.contains(.command)

        if cmdPressed && event.keyCode == 49 { // 49 is space key
            callback()
        }
    }
}

// EventMonitor class for global event monitoring
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
