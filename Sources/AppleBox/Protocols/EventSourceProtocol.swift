import CoreGraphics

/// Keep clipboard replay from posting keyboard events to an unspecified app.
public protocol EventSourceProtocol {
    var canPostPaste: Bool { get }

    /// A successful request does not confirm that the destination handled paste.
    func postPaste(to process: pid_t) -> Bool
}
