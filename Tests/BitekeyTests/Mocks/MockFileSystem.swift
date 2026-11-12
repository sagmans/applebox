@testable import Bitekey
import Foundation

/// Mock implementation of FileSystemProtocol for testing.
///
/// Production code calls it from background queues; `@unchecked Sendable` is safe because every
/// mutable property is read and written under `stateLock`.
final nonisolated class MockFileSystem: FileSystemProtocol, @unchecked Sendable {
    private let stateLock = NSLock()

    private func withStateLock<T>(_ work: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try work()
    }

    // MARK: - Configurable Properties

    private var _mockHomeDirectory: URL = .init(fileURLWithPath: "/Users/testuser")
    var mockHomeDirectory: URL {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _mockHomeDirectory }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_mockHomeDirectory }
    }

    private var _mockURLs: [URL] = []
    var mockURLs: [URL] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _mockURLs }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_mockURLs }
    }

    private var _existingFiles: [String: Bool] = [:]
    var existingFiles: [String: Bool] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _existingFiles }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_existingFiles }
    }

    private var _directoryFlags: [String: Bool] = [:]
    var directoryFlags: [String: Bool] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _directoryFlags }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_directoryFlags }
    }

    private var _directoryContents: [URL: [URL]] = [:]
    var directoryContents: [URL: [URL]] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _directoryContents }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_directoryContents }
    }

    private var _fileContents: [String: Data] = [:]
    var fileContents: [String: Data] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _fileContents }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_fileContents }
    }

    private var _contentsOfDirectoryError: Error?
    var contentsOfDirectoryError: Error? {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _contentsOfDirectoryError }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_contentsOfDirectoryError }
    }

    private var _createDirectoryError: Error?
    var createDirectoryError: Error? {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _createDirectoryError }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_createDirectoryError }
    }

    private var _itemKinds: [String: FileItemKind] = [:]
    /// Kind reported per path; a path that is absent here reads as `.missing`.
    var itemKinds: [String: FileItemKind] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _itemKinds }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_itemKinds }
    }

    private var _itemKindError: Error?
    var itemKindError: Error? {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _itemKindError }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_itemKindError }
    }

    private var _copyItemError: Error?
    var copyItemError: Error? {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _copyItemError }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_copyItemError }
    }

    private var _moveItemError: Error?
    var moveItemError: Error? {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _moveItemError }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_moveItemError }
    }

    private var _removeItemError: Error?
    var removeItemError: Error? {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _removeItemError }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_removeItemError }
    }

    // MARK: - Invocation Tracking

    private var _copyItemCalls: [(source: URL, destination: URL)] = []
    var copyItemCalls: [(source: URL, destination: URL)] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _copyItemCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_copyItemCalls }
    }

    private var _moveItemCalls: [(source: URL, destination: URL)] = []
    var moveItemCalls: [(source: URL, destination: URL)] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _moveItemCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_moveItemCalls }
    }

    private var _removeItemCalls: [URL] = []
    var removeItemCalls: [URL] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _removeItemCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_removeItemCalls }
    }

    private var _fileExistsAtPathCalls: [String] = []
    var fileExistsAtPathCalls: [String] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _fileExistsAtPathCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_fileExistsAtPathCalls }
    }

    private var _fileExistsWithDirectoryCalls: [(path: String, isDirectory: Bool)] = []
    var fileExistsWithDirectoryCalls: [(path: String, isDirectory: Bool)] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _fileExistsWithDirectoryCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_fileExistsWithDirectoryCalls }
    }

    private var _contentsOfDirectoryCalls: [URL] = []
    var contentsOfDirectoryCalls: [URL] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _contentsOfDirectoryCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_contentsOfDirectoryCalls }
    }

    private var _createDirectoryCalls: [(url: URL, createIntermediates: Bool)] = []
    var createDirectoryCalls: [(url: URL, createIntermediates: Bool)] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _createDirectoryCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_createDirectoryCalls }
    }

    private var _contentsAtPathCalls: [String] = []
    var contentsAtPathCalls: [String] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _contentsAtPathCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_contentsAtPathCalls }
    }

    private var _createFileCalls: [(path: String, data: Data?)] = []
    var createFileCalls: [(path: String, data: Data?)] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _createFileCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_createFileCalls }
    }

    private var _urlsCalls: [(directory: FileManager.SearchPathDirectory, domainMask: FileManager.SearchPathDomainMask)] = []
    var urlsCalls: [(directory: FileManager.SearchPathDirectory, domainMask: FileManager.SearchPathDomainMask)] {
        _read { stateLock.lock(); defer { stateLock.unlock() }; yield _urlsCalls }
        _modify { stateLock.lock(); defer { stateLock.unlock() }; yield &_urlsCalls }
    }

    // MARK: - FileSystemProtocol Implementation

    var homeDirectoryForCurrentUser: URL {
        mockHomeDirectory
    }

    func displayName(atPath path: String) -> String {
        (path as NSString).lastPathComponent
    }

    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        urlsCalls.append((directory: directory, domainMask: domainMask))
        return mockURLs
    }

    func fileExists(atPath path: String) -> Bool {
        fileExistsAtPathCalls.append(path)
        return existingFiles[path] ?? false
    }

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let exists = existingFiles[path] ?? false
        let isDir = directoryFlags[path] ?? false
        fileExistsWithDirectoryCalls.append((path: path, isDirectory: isDir))
        isDirectory?.pointee = ObjCBool(isDir)
        return exists
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys _: [URLResourceKey]?, options _: FileManager.DirectoryEnumerationOptions, limit: Int) throws -> [URL] {
        contentsOfDirectoryCalls.append(url)
        if let error = contentsOfDirectoryError {
            throw error
        }
        return Array((directoryContents[url] ?? []).prefix(limit))
    }

    func isApplicationSearchFolder(at url: URL) -> Bool {
        directoryFlags[url.path] == true && url.pathExtension.isEmpty
    }

    func isApplicationBundle(at url: URL) -> Bool {
        // The fixture directory flag stands in for the native bundle structure check.
        existingFiles[url.path] == true && directoryFlags[url.path] == true
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes _: [FileAttributeKey: Any]?) throws {
        createDirectoryCalls.append((url: url, createIntermediates: createIntermediates))
        if let error = createDirectoryError {
            throw error
        }
        // Mark directory as existing
        existingFiles[url.path] = true
        directoryFlags[url.path] = true
    }

    func contents(atPath path: String) -> Data? {
        contentsAtPathCalls.append(path)
        return fileContents[path]
    }

    func createFile(atPath path: String, contents data: Data?, attributes _: [FileAttributeKey: Any]?) -> Bool {
        createFileCalls.append((path: path, data: data))
        // Store the data for later retrieval
        if let data {
            fileContents[path] = data
        }
        existingFiles[path] = true
        directoryFlags[path] = false
        return true
    }

    func write(_ data: Data, to url: URL, options _: Data.WritingOptions) throws {
        // Keep tracking consistent with createFile, since production code may switch to Data.write.
        createFileCalls.append((path: url.path, data: data))
        fileContents[url.path] = data
        existingFiles[url.path] = true
        directoryFlags[url.path] = false
    }

    func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data? {
        guard let data = contents(atPath: url.path) else { return nil }
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        try write(data, to: url, options: [.atomic])
    }

    func removePrivateFile(at url: URL) throws {
        fileContents[url.path] = nil
        existingFiles[url.path] = nil
        directoryFlags[url.path] = nil
    }

    func itemKind(at url: URL) throws -> FileItemKind {
        try withStateLock {
            if let error = _itemKindError {
                throw error
            }
            return _itemKinds[url.path] ?? .missing
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try withStateLock {
            _copyItemCalls.append((source: source, destination: destination))
            if let error = _copyItemError {
                throw error
            }
            placeItem(from: source.path, to: destination.path)
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try withStateLock {
            _moveItemCalls.append((source: source, destination: destination))
            if let error = _moveItemError {
                throw error
            }
            placeItem(from: source.path, to: destination.path)
            _existingFiles[source.path] = nil
            _directoryFlags[source.path] = nil
            _itemKinds[source.path] = nil
        }
    }

    func removeItem(at url: URL) throws {
        try withStateLock {
            _removeItemCalls.append(url)
            if let error = _removeItemError {
                throw error
            }
            _existingFiles[url.path] = nil
            _directoryFlags[url.path] = nil
            _itemKinds[url.path] = nil
        }
    }

    /// Mirrors the source flags onto the destination; caller must hold `stateLock`.
    private func placeItem(from source: String, to destination: String) {
        _existingFiles[destination] = true
        _directoryFlags[destination] = _directoryFlags[source] ?? false
        _itemKinds[destination] = _itemKinds[source]
    }

    // MARK: - Helper Methods

    /// Clears all recorded invocations
    func resetInvocations() {
        fileExistsAtPathCalls = []
        fileExistsWithDirectoryCalls = []
        contentsOfDirectoryCalls = []
        createDirectoryCalls = []
        contentsAtPathCalls = []
        createFileCalls = []
        urlsCalls = []
    }

    /// Adds a file to the mock file system
    func addFile(at path: String, contents: Data? = nil, isDirectory: Bool = false) {
        existingFiles[path] = true
        directoryFlags[path] = isDirectory
        if let contents {
            fileContents[path] = contents
        }
    }

    /// Adds a directory with contents to the mock file system
    func addDirectory(at url: URL, contents: [URL]) {
        existingFiles[url.path] = true
        directoryFlags[url.path] = true
        directoryContents[url] = contents
    }
}
