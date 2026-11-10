import Foundation

/// Production implementation of FileSystemProtocol wrapping FileManager.default
public final class SystemFileManager: FileSystemProtocol {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public var homeDirectoryForCurrentUser: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    public func displayName(atPath path: String) -> String {
        fileManager.displayName(atPath: path)
    }

    public func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        fileManager.urls(for: directory, in: domainMask)
    }

    public func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    public func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    public func contents(atPath path: String) -> Data? {
        fileManager.contents(atPath: path)
    }

    public func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool {
        fileManager.createFile(atPath: path, contents: data, attributes: attr)
    }

    public func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }
}
