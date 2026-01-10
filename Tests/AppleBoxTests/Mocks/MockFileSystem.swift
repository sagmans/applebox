import Foundation
@testable import AppleBox

/// Mock implementation of FileSystemProtocol for testing
final class MockFileSystem: FileSystemProtocol {
    // MARK: - Configurable Properties

    /// Configurable home directory URL
    var mockHomeDirectory: URL = URL(fileURLWithPath: "/Users/testuser")

    /// Configurable URLs returned by urls(for:in:)
    var mockURLs: [URL] = []

    /// Dictionary mapping paths to whether they exist
    var existingFiles: [String: Bool] = [:]

    /// Dictionary mapping paths to whether they are directories
    var directoryFlags: [String: Bool] = [:]

    /// Dictionary mapping directory URLs to their contents
    var directoryContents: [URL: [URL]] = [:]

    /// Dictionary mapping file paths to their Data contents
    var fileContents: [String: Data] = [:]

    /// Error to throw from contentsOfDirectory if set
    var contentsOfDirectoryError: Error?

    /// Error to throw from createDirectory if set
    var createDirectoryError: Error?

    // MARK: - Invocation Tracking

    /// Tracks all fileExists(atPath:) calls
    var fileExistsAtPathCalls: [String] = []

    /// Tracks all fileExists(atPath:isDirectory:) calls
    var fileExistsWithDirectoryCalls: [(path: String, isDirectory: Bool)] = []

    /// Tracks all contentsOfDirectory calls
    var contentsOfDirectoryCalls: [URL] = []

    /// Tracks all createDirectory calls
    var createDirectoryCalls: [(url: URL, createIntermediates: Bool)] = []

    /// Tracks all contents(atPath:) calls
    var contentsAtPathCalls: [String] = []

    /// Tracks all createFile calls
    var createFileCalls: [(path: String, data: Data?)] = []

    /// Tracks all urls(for:in:) calls
    var urlsCalls: [(directory: FileManager.SearchPathDirectory, domainMask: FileManager.SearchPathDomainMask)] = []

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
