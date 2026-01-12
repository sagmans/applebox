import AppKit

enum HotkeyMode {
    case application
    case clipboard
}

class HotkeyManager {
    private var eventMonitor: EventMonitor?
    private let callback: (HotkeyMode) -> Void

    init(callback: @escaping (HotkeyMode) -> Void) {
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
        // Cmd+Space for app mode, Opt+Space for clipboard mode
        let cmdPressed = event.modifierFlags.contains(.command)
        let optPressed = event.modifierFlags.contains(.option)

        if event.keyCode == 49 { // 49 is space key
            if cmdPressed {
                callback(.application)
            } else if optPressed {
                callback(.clipboard)
            }
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
