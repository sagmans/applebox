import AppKit

/// Production implementation of PasteboardProtocol wrapping NSPasteboard.general
public final class SystemPasteboard: PasteboardProtocol {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public var types: [NSPasteboard.PasteboardType]? {
        pasteboard.types
    }

    public func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        pasteboard.string(forType: dataType)
    }

    public func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.data(forType: dataType)
    }

    @discardableResult
    public func clearContents() -> Int {
        pasteboard.clearContents()
    }

    @discardableResult
    public func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setString(string, forType: dataType)
    }

    public func replaceData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        // Prepare the typed item before clearing the user's current clipboard.
        let item = NSPasteboardItem()
        guard item.setData(data, forType: dataType) else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
