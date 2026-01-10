import AppKit

/// Protocol abstracting NSPasteboard operations for testability
public protocol PasteboardProtocol {
    /// The receiver's change count
    var changeCount: Int { get }

    /// Returns a string for the specified type from the first item in the pasteboard
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?

    /// Clears the contents of the pasteboard
    @discardableResult
    func clearContents() -> Int

    /// Sets the given string as the representation for the specified type
    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}
