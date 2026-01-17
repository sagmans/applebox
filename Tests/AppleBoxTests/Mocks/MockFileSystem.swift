import Foundation
@testable import AppleBox

/// Mock implementation of FileSystemProtocol for testing
final class MockFileSystem: FileSystemProtocol {
    private let stateLock = NSLock()

    private func withStateLock<T>(_ work: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try work()
    }

    // MARK: - Configurable Properties

    private var _mockHomeDirectory: URL = URL(fileURLWithPath: "/Users/testuser")
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

    // MARK: - Invocation Tracking

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
        return mockHomeDirectory
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

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        contentsOfDirectoryCalls.append(url)
        if let error = contentsOfDirectoryError {
            throw error
        }
        return directoryContents[url] ?? []
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
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

    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool {
        createFileCalls.append((path: path, data: data))
        // Store the data for later retrieval
        if let data = data {
            fileContents[path] = data
        }
        existingFiles[path] = true
        directoryFlags[path] = false
        return true
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
        if let contents = contents {
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
