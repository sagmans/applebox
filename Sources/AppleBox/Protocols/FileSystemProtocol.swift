import Foundation

/// Protocol abstracting FileManager operations for testability.
///
/// Nonisolated and Sendable because indexing and clipboard persistence call it
/// from background queues; conformers must be safe to share across threads.
public nonisolated protocol FileSystemProtocol: Sendable {
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

    /// Return a bounded shallow listing so a large folder cannot exhaust the indexer.
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, limit: Int) throws -> [URL]

    /// Avoid traversing packages and links that can leave the application's search roots.
    func isApplicationSearchFolder(at url: URL) -> Bool

    /// Exclude directories that have an app extension but lack a launchable bundle structure.
    func isApplicationBundle(at url: URL) -> Bool

    /// Creates a directory with the given attributes at the specified URL
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws

    /// Returns the contents of the file at the specified path
    func contents(atPath path: String) -> Data?

    /// Creates a file with the specified content at the given location
    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool

    /// Writes data to the specified URL (supports atomic writes via options)
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws

    /// Keep clipboard archives owner-only and refuse to read past the migration bound.
    func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data?

    /// Replace a clipboard archive without exposing its temporary file or following links.
    func writePrivateFile(_ data: Data, to url: URL) throws
}

/// Extension to provide default implementations for overloaded methods
public nonisolated extension FileSystemProtocol {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        try data.write(to: url, options: options)
    }
}
