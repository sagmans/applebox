import AppKit
import Carbon.HIToolbox
import OSLog

enum HotkeyMode: String, CaseIterable {
    case application
    case clipboard

    var defaultPreset: HotkeyPreset {
        self == .application ? .commandSpace : .optionSpace
    }

    var fallbackPreset: HotkeyPreset {
        self == .application ? .commandF1 : .commandF2
    }
}

/// Use named choices so restoring preferences cannot register an arbitrary key code.
enum HotkeyPreset: String, CaseIterable {
    case commandSpace
    case commandOptionV
    case optionSpace
    case controlSpace
    case commandShiftSpace
    case optionShiftSpace
    case controlOptionSpace
    case controlShiftSpace
    case commandF1
    case commandF2
    case controlOptionF1
    case controlOptionF2

    var chord: (label: String, key: UInt32, modifiers: UInt32) {
        switch self {
        case .commandSpace: ("⌘Space", UInt32(kVK_Space), UInt32(cmdKey))
        case .commandOptionV: ("⌥⌘V", UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey))
        case .optionSpace: ("⌥Space", UInt32(kVK_Space), UInt32(optionKey))
        case .controlSpace: ("⌃Space", UInt32(kVK_Space), UInt32(controlKey))
        case .commandShiftSpace: ("⇧⌘Space", UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .optionShiftSpace: ("⌥⇧Space", UInt32(kVK_Space), UInt32(optionKey | shiftKey))
        case .controlOptionSpace: ("⌃⌥Space", UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlShiftSpace: ("⌃⇧Space", UInt32(kVK_Space), UInt32(controlKey | shiftKey))
        case .commandF1: ("⌘F1", UInt32(kVK_F1), UInt32(cmdKey))
        case .commandF2: ("⌘F2", UInt32(kVK_F2), UInt32(cmdKey))
        case .controlOptionF1: ("⌃⌥F1", UInt32(kVK_F1), UInt32(controlKey | optionKey))
        case .controlOptionF2: ("⌃⌥F2", UInt32(kVK_F2), UInt32(controlKey | optionKey))
        }
    }
}

final class HotkeyManager {
    private struct Registration {
        let id: UInt32
        let preset: HotkeyPreset
        let reference: EventHotKeyRef
    }

    private static let signature: OSType = 0x4142_4F58
    private static let preferencePrefix = "GlobalShortcut."
    private let callback: (HotkeyMode) -> Void
    private let preferences: UserDefaults
    private var eventHandler: EventHandlerRef?
    private var active: [HotkeyMode: Registration] = [:]
    private var nextID: UInt32 = 1
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox", category: "hotkey")

    init(preferences: UserDefaults = .standard, callback: @escaping (HotkeyMode) -> Void) {
        self.preferences = preferences
        self.callback = callback
    }

    deinit {
        stop()
    }

    func preferredPreset(for mode: HotkeyMode) -> HotkeyPreset {
        preferences.string(forKey: preferenceKey(for: mode)).flatMap(HotkeyPreset.init(rawValue:)) ?? mode.defaultPreset
    }

    func activePreset(for mode: HotkeyMode) -> HotkeyPreset? {
        active[mode]?.preset
    }

    func start() {
        guard installHandler() else { return }
        for mode in HotkeyMode.allCases {
            let preferred = preferredPreset(for: mode)
            if !register(preferred, for: mode), active[mode] == nil, preferred != mode.fallbackPreset {
                _ = register(mode.fallbackPreset, for: mode)
            }
        }
    }

    func choose(_ preset: HotkeyPreset, for mode: HotkeyMode) -> Bool {
        guard installHandler(), register(preset, for: mode) else { return false }
        preferences.set(preset.rawValue, forKey: preferenceKey(for: mode))
        return true
    }

    func stop() {
        for registration in active.values {
            UnregisterEventHotKey(registration.reference)
        }
        active.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register(_ preset: HotkeyPreset, for mode: HotkeyMode) -> Bool {
        let previous = active[mode]
        if previous?.preset == preset {
            return true
        }
        guard !active.values.contains(where: { $0.preset == preset }) else { return false }

        // Register the replacement first so a conflict leaves the working chord in place.
        let chord = preset.chord
        let id = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.key, chord.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            logger.notice("Global shortcut unavailable for \(mode.rawValue, privacy: .public): \(status, privacy: .public)")
            return false
        }
        if let previous, UnregisterEventHotKey(previous.reference) != noErr {
            UnregisterEventHotKey(reference)
            logger.error("Could not replace global shortcut for \(mode.rawValue, privacy: .public)")
            return false
        }
        active[mode] = Registration(id: id, preset: preset, reference: reference)
        return true
    }

    private func preferenceKey(for mode: HotkeyMode) -> String {
        Self.preferencePrefix + mode.rawValue
    }

    private func installHandler() -> Bool {
        if eventHandler != nil {
            return true
        }

        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let event, let info else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
            return manager.handle(event)
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            logger.error("Cannot install global shortcut handler: \(status, privacy: .public)")
            return false
        }
        return true
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == Self.signature,
              let mode = active.first(where: { $0.value.id == id.id })?.key else { return OSStatus(eventNotHandledErr) }
        callback(mode)
        return noErr
    }
}
