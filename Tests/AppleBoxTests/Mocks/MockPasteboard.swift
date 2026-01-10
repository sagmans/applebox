import AppKit
@testable import AppleBox

/// Mock implementation of PasteboardProtocol for testing
final class MockPasteboard: PasteboardProtocol {
    // MARK: - Configurable Properties

    /// The current change count (incremented on each modification)
    private(set) var mockChangeCount: Int = 0

    /// The current string content of the pasteboard
    private(set) var mockStringContent: String?

    // MARK: - Invocation Tracking

    /// Tracks all string(forType:) calls with their type
    var stringForTypeCalls: [NSPasteboard.PasteboardType] = []

    /// Tracks all clearContents() calls
    var clearContentsCalls: Int = 0

    /// Tracks all setString(forType:) calls
    var setStringCalls: [(string: String, type: NSPasteboard.PasteboardType)] = []

    // MARK: - PasteboardProtocol Implementation

    var changeCount: Int {
        return mockChangeCount
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        stringForTypeCalls.append(dataType)
        return mockStringContent
    }

    @discardableResult
    func clearContents() -> Int {
        clearContentsCalls += 1
        mockStringContent = nil
        mockChangeCount += 1
        return mockChangeCount
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        setStringCalls.append((string: string, type: dataType))
        mockStringContent = string
        mockChangeCount += 1
        return true
    }

    // MARK: - Helper Methods

    /// Clears all recorded invocations
    func resetInvocations() {
        stringForTypeCalls = []
        clearContentsCalls = 0
        setStringCalls = []
    }

    /// Simulates external clipboard change (like another app copying)
    func simulateExternalChange(content: String?) {
        mockStringContent = content
        mockChangeCount += 1
    }

    /// Sets the initial state without incrementing change count
    func setInitialState(content: String?, changeCount: Int) {
        mockStringContent = content
        mockChangeCount = changeCount
    }
}
