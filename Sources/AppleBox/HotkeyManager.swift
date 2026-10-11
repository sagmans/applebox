import AppKit
import Carbon.HIToolbox
import OSLog

enum HotkeyMode {
    case application
    case clipboard
}

final class HotkeyManager {
    private enum HotkeyId: UInt32 {
        case application = 1
        case clipboard = 2
        case applicationAlt = 3 // Cmd+F1 alternative
        case clipboardAlt = 4 // Cmd+F2 alternative
    }

    private let callback: (HotkeyMode) -> Void

    // Carbon hotkey registration (preferred).
    private static let hotKeySignature: OSType = 0x4142_4F58 // 'ABOX'
    private var eventHandler: EventHandlerRef?
    private var registeredHotKeys: [HotkeyId: EventHotKeyRef?] = [:]

    /// NSEvent fallback (requires Input Monitoring for keyDown).
    private var eventMonitor: EventMonitor?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox",
        category: "hotkey"
    )

    init(callback: @escaping (HotkeyMode) -> Void) {
        self.callback = callback
    }

    func start() {
        let carbonOk = installHotkeyHandlerIfNeeded() && registerCarbonHotkeys()

        if !carbonOk {
            logger.warning("Falling back to NSEvent global monitor")
            startEventMonitorFallback()
        }
    }

    func stop() {
        unregisterCarbonHotkeys()
        removeHotkeyHandlerIfNeeded()
        eventMonitor?.stop()
        eventMonitor = nil
    }

    // MARK: - Carbon HotKeys

    private func installHotkeyHandlerIfNeeded() -> Bool {
        if eventHandler != nil {
            return true
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyId = EventHotKeyID()
                let getStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyId
                )

                guard getStatus == noErr else {
                    manager.logger.error("GetEventParameter failed: \(getStatus)")
                    return getStatus
                }

                guard hotKeyId.signature == HotkeyManager.hotKeySignature else { return noErr }

                switch hotKeyId.id {
                case HotkeyId.application.rawValue:
                    manager.logger.debug("Hotkey pressed: cmd+space")
                    manager.callback(.application)
                case HotkeyId.clipboard.rawValue:
                    manager.logger.debug("Hotkey pressed: opt+space")
                    manager.callback(.clipboard)
                case HotkeyId.applicationAlt.rawValue:
                    manager.logger.debug("Hotkey pressed: cmd+F1")
                    manager.callback(.application)
                case HotkeyId.clipboardAlt.rawValue:
                    manager.logger.debug("Hotkey pressed: cmd+F2")
                    manager.callback(.clipboard)
                default:
                    break
                }

                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        if status != noErr {
            logger.error("InstallEventHandler failed: \(status)")
            return false
        }

        return true
    }

    private func removeHotkeyHandlerIfNeeded() {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    private func registerCarbonHotkeys() -> Bool {
        // Primary shortcuts
        let cmdOk = registerCarbonHotkey(id: .application, keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        let optOk = registerCarbonHotkey(id: .clipboard, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        // Alternative shortcuts: Cmd+F1 and Cmd+F2
        let cmdF1Ok = registerCarbonHotkey(id: .applicationAlt, keyCode: UInt32(kVK_F1), modifiers: UInt32(cmdKey))
        let cmdF2Ok = registerCarbonHotkey(id: .clipboardAlt, keyCode: UInt32(kVK_F2), modifiers: UInt32(cmdKey))
        return cmdOk || optOk || cmdF1Ok || cmdF2Ok
    }

    private func registerCarbonHotkey(id: HotkeyId, keyCode: UInt32, modifiers: UInt32) -> Bool {
        if registeredHotKeys[id] != nil {
            return true
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.hotKeySignature, id: id.rawValue)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status != noErr {
            logger.error("RegisterEventHotKey failed for \(id.rawValue): \(status)")
            return false
        }

        registeredHotKeys[id] = ref
        logger.info("Registered hotkey id=\(id.rawValue)")
        return true
    }

    private func unregisterCarbonHotkeys() {
        for (_, ref) in registeredHotKeys {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        registeredHotKeys.removeAll()
    }

    // MARK: - NSEvent Fallback

    private func startEventMonitorFallback() {
        eventMonitor = EventMonitor(mask: .keyDown) { [weak self] event in
            self?.handleKeyEventFallback(event)
        }
        eventMonitor?.start()
    }

    private func handleKeyEventFallback(_ event: NSEvent) {
        // Cmd+Space for app mode, Opt+Space for clipboard mode
        // Alt: Cmd+F1 for app mode, Cmd+F2 for clipboard mode
        let cmdPressed = event.modifierFlags.contains(.command)
        let optPressed = event.modifierFlags.contains(.option)

        if event.keyCode == 49 { // 49 is space key
            if cmdPressed {
                logger.debug("Fallback key event: cmd+space")
                callback(.application)
            } else if optPressed {
                logger.debug("Fallback key event: opt+space")
                callback(.clipboard)
            }
        } else if cmdPressed, event.keyCode == 122 { // F1
            logger.debug("Fallback key event: cmd+F1")
            callback(.application)
        } else if cmdPressed, event.keyCode == 120 { // F2
            logger.debug("Fallback key event: cmd+F2")
            callback(.clipboard)
        }
    }
}

/// EventMonitor class for global event monitoring
final class EventMonitor {
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
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
