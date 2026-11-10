import AppKit
@testable import AppleBox

/// Mock implementation of WorkspaceProtocol for testing
final class MockWorkspace: WorkspaceProtocol {
    var frontmostApplication: NSRunningApplication?

    // MARK: - Configurable Properties

    /// If set, the completion handler will be called with this running application
    var mockRunningApplication: NSRunningApplication?

    /// If set, the completion handler will be called with this error
    var mockOpenError: Error?

    /// Whether openApplication should call completion handler immediately (sync) or asynchronously
    var callCompletionSynchronously: Bool = true

    // MARK: - Invocation Tracking

    /// Recorded openApplication calls
    struct OpenApplicationCall {
        let applicationURL: URL
        let configuration: NSWorkspace.OpenConfiguration
        let hasCompletionHandler: Bool
    }

    /// Tracks all openApplication calls
    var openApplicationCalls: [OpenApplicationCall] = []

    // MARK: - WorkspaceProtocol Implementation

    func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration, completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?) {
        let call = OpenApplicationCall(
            applicationURL: applicationURL,
            configuration: configuration,
            hasCompletionHandler: completionHandler != nil
        )
        openApplicationCalls.append(call)

        // Call completion handler if provided
        if let completionHandler {
            if callCompletionSynchronously {
                completionHandler(mockRunningApplication, mockOpenError)
            } else {
                DispatchQueue.main.async { [weak self] in
                    completionHandler(self?.mockRunningApplication, self?.mockOpenError)
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// Clears all recorded invocations
    func resetInvocations() {
        openApplicationCalls = []
    }

    /// Returns the last application URL that was opened
    var lastOpenedApplicationURL: URL? {
        openApplicationCalls.last?.applicationURL
    }

    /// Returns the number of times openApplication was called
    var openApplicationCallCount: Int {
        openApplicationCalls.count
    }
}
