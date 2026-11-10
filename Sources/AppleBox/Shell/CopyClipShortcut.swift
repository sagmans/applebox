import AppKit

/// The copy-clip key chord (Option-Return). One definition is shared by the panel's key routing and the
/// row and footer hints that advertise it, so the chord the panel reserves and the chord the hints name
/// cannot drift.
enum CopyClipShortcut {
    static let key = "\r"
    static let modifiers: NSEvent.ModifierFlags = .option
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
}
