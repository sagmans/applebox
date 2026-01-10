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

    public func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        pasteboard.string(forType: dataType)
    }

    @discardableResult
    public func clearContents() -> Int {
        pasteboard.clearContents()
    }

    @discardableResult
    public func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setString(string, forType: dataType)
    }
}
