import AppKit

/// Protocol abstracting NSPasteboard operations for testability
public protocol PasteboardProtocol {
    /// The receiver's change count
    var changeCount: Int { get }

    /// Check privacy markers without asking the owner to supply the payload.
    var types: [NSPasteboard.PasteboardType]? { get }

    /// Returns a string for the specified type from the first item in the pasteboard
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?

    /// Returns data for the specified type from the first item in the pasteboard
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?

    /// Clears the contents of the pasteboard
    @discardableResult
    func clearContents() -> Int

    /// Sets the given string as the representation for the specified type
    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool

    /// Preserve the representation's type for consumers that expect image data.
    func replaceData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) -> Bool
}
