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

    public func replayData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) -> Int? {
        // Prepare the typed item before clearing the user's current clipboard.
        let item = NSPasteboardItem()
        guard item.setData(data, forType: dataType),
              item.setData(Data(), forType: .generatedClipboardContent) else { return nil }

        let ownership = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]), pasteboard.changeCount == ownership else { return nil }
        return ownership
    }
}
