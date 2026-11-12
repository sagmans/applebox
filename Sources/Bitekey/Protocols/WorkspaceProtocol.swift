import AppKit

/// Protocol abstracting NSWorkspace operations for testability
public protocol WorkspaceProtocol {
    /// Identify the app that owns focus before Bitekey activates.
    var frontmostApplication: NSRunningApplication? { get }

    /// Opens the application at the specified URL asynchronously
    /// - Parameters:
    ///   - applicationURL: The URL of the application to open
    ///   - configuration: The configuration options for opening the application
    ///   - completionHandler: A closure called when the operation completes
    func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration, completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?)
}
