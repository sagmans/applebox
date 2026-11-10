import CoreGraphics

/// Keep clipboard replay from posting keyboard events to an unspecified app.
public protocol EventSourceProtocol {
    var canPostPaste: Bool { get }

    /// Asks macOS to list the app in the paste permission pane so the user can grant paste. Without a request
    /// the app never appears there and the user cannot find what to enable.
    func requestPostAccess()

    /// A successful request does not confirm that the destination handled paste.
    func postPaste(to process: pid_t) -> Bool
}
