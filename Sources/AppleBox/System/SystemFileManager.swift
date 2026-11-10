import Foundation

/// Production implementation of FileSystemProtocol wrapping FileManager.default
public final class SystemFileManager: FileSystemProtocol {
    private let fileManager: FileManager
    private let applicationPackageTypeKey = "CFBundlePackageType"
    private let applicationPackageType = "APPL"
    private let searchFolderKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]

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

    public func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, limit: Int) throws -> [URL] {
        var failure: Error?
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: mask.union(.skipsSubdirectoryDescendants)) { _, error in
            failure = error
            return false
        }
        var entries: [URL] = []
        while entries.count < limit, let entry = enumerator?.nextObject() as? URL {
            entries.append(entry)
        }
        if let failure {
            throw failure
        }
        return entries
    }

    public func isApplicationSearchFolder(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: searchFolderKeys) else { return false }
        return values.isDirectory == true && values.isPackage == false && values.isSymbolicLink == false
    }

    public func isApplicationBundle(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              bundle.infoDictionary?[applicationPackageTypeKey] as? String == applicationPackageType,
              let executable = bundle.executableURL?.resolvingSymlinksInPath(),
              let values = try? executable.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true, fileManager.isExecutableFile(atPath: executable.path) else { return false }

        // Bundle metadata must not redirect the executable to an unrelated file.
        var relationship = FileManager.URLRelationship.other
        try? fileManager.getRelationship(&relationship, ofDirectoryAt: url.resolvingSymlinksInPath(), toItemAt: executable)
        return relationship == .contains
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
