import AppKit
@testable import AppleBox

/// Mock implementation of PasteboardProtocol for testing
final class MockPasteboard: PasteboardProtocol {
    // MARK: - Configurable Properties

    /// The current change count (incremented on each modification)
    private(set) var mockChangeCount: Int = 0

    /// The current string content of the pasteboard
    private(set) var mockStringContent: String?

    /// The current image data (PNG or TIFF)
    private(set) var mockImageData: [NSPasteboard.PasteboardType: Data] = [:]
    private var didReplay = false

    // MARK: - Invocation Tracking

    /// Tracks all string(forType:) calls with their type
    var stringForTypeCalls: [NSPasteboard.PasteboardType] = []

    /// Tracks all data(forType:) calls with their type
    var dataForTypeCalls: [NSPasteboard.PasteboardType] = []

    /// Tracks all clearContents() calls
    var clearContentsCalls: Int = 0

    /// Tracks all setString(forType:) calls
    var setStringCalls: [(string: String, type: NSPasteboard.PasteboardType)] = []

    // MARK: - PasteboardProtocol Implementation

    let readAccess = ClipboardReadAccess.allowed

    var changeCount: Int {
        mockChangeCount
    }

    var types: [NSPasteboard.PasteboardType]? {
        Array(mockImageData.keys) + (mockStringContent == nil ? [] : [.string]) +
            (didReplay ? [.generatedClipboardContent] : [])
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        stringForTypeCalls.append(dataType)
        return mockStringContent
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        dataForTypeCalls.append(dataType)
        return mockImageData[dataType]
    }

    func replayData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) -> Int? {
        if dataType == .string {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            setStringCalls.append((string: text, type: dataType))
            simulateExternalChange(content: text)
        } else {
            simulateExternalImageChange(imageData: data, type: dataType)
        }
        clearContentsCalls += 1
        didReplay = true
        return changeCount
    }

    // MARK: - Helper Methods

    /// Clears all recorded invocations
    func resetInvocations() {
        stringForTypeCalls = []
        dataForTypeCalls = []
        clearContentsCalls = 0
        setStringCalls = []
    }

    /// Simulates external clipboard change (like another app copying)
    func simulateExternalChange(content: String?) {
        didReplay = false
        mockStringContent = content
        mockImageData = [:]
        mockChangeCount += 1
    }

    /// Simulates external clipboard change with image data
    func simulateExternalImageChange(imageData: Data, type: NSPasteboard.PasteboardType = .png) {
        didReplay = false
        mockStringContent = nil
        mockImageData = [type: imageData]
        mockChangeCount += 1
    }

    /// Sets the initial state without incrementing change count
    func setInitialState(content: String?, changeCount: Int) {
        didReplay = false
        mockStringContent = content
        mockChangeCount = changeCount
    }
}
