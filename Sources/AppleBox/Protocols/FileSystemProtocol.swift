import Foundation

/// Protocol abstracting FileManager operations for testability
public protocol FileSystemProtocol {
    /// Returns the home directory URL for the current user
    var homeDirectoryForCurrentUser: URL { get }

    /// Match the localized name that a person sees in Finder.
    func displayName(atPath path: String) -> String

    /// Returns an array of URLs for the specified directory in the specified domains
    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL]

    /// Returns a Boolean value that indicates whether a file or directory exists at a specified path
    func fileExists(atPath path: String) -> Bool

    /// Returns a Boolean value that indicates whether a file or directory exists at a specified path,
    /// and optionally whether it is a directory
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool

    /// Performs a shallow search of the specified directory and returns URLs for the contained items
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]

    /// Creates a directory with the given attributes at the specified URL
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws

    /// Returns the contents of the file at the specified path
    func contents(atPath path: String) -> Data?

    /// Creates a file with the specified content at the given location
    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool

    /// Writes data to the specified URL (supports atomic writes via options)
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
}

/// Extension to provide default implementations for overloaded methods
public extension FileSystemProtocol {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        try data.write(to: url, options: options)
    }
}
