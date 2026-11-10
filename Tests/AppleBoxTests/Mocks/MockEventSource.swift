@testable import AppleBox
import CoreGraphics

/// Record requests at the process boundary without sending keys during tests.
final class MockEventSource: EventSourceProtocol {
    var canPostPaste = true
    private(set) var pasteTargets: [pid_t] = []
    private(set) var accessRequestCount = 0

    func requestPostAccess() {
        accessRequestCount += 1
    }

    func postPaste(to process: pid_t) -> Bool {
        pasteTargets.append(process)
        return true
    }

    func resetInvocations() {
        pasteTargets = []
        accessRequestCount = 0
    }
}
