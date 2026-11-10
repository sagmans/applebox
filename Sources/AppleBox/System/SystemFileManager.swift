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

private enum PrivateFileError: Error {
    case unsafeOwnerOrType
    case exceedsReadLimit
    case changedDuringRead
}

extension SystemFileManager {
    private static let ownerFileMode: mode_t = 0o600
    private static let ownerDirectoryMode: mode_t = 0o700
    private static let permissionMask: mode_t = 0o7777

    public func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw PrivateFileError.exceedsReadLimit }
        let directory = try openPrivateDirectory(for: url)
        defer { close(directory) }

        // Reject symlinks and avoid waiting on a non-regular file before validation.
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw posixFailure()
        }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let info = try protect(descriptor, type: mode_t(S_IFREG), permissions: Self.ownerFileMode)
        guard (0 ... Int64(maximumBytes)).contains(info.st_size) else { throw PrivateFileError.exceedsReadLimit }
        let expectedSize = Int(info.st_size)
        let data = try file.read(upToCount: expectedSize + 1) ?? Data()
        guard data.count == expectedSize else { throw PrivateFileError.changedDuringRead }
        return data
    }

    public func writePrivateFile(_ data: Data, to url: URL) throws {
        let directory = try openPrivateDirectory(for: url)
        defer { close(directory) }

        // A same-directory replacement keeps the old archive intact until the new file is complete.
        let temporaryName = UUID().uuidString
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, Self.ownerFileMode)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { unlinkat(directory, temporaryName, 0) }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        _ = try protect(descriptor, type: mode_t(S_IFREG), permissions: Self.ownerFileMode)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard renameat(directory, temporaryName, directory, url.lastPathComponent) == 0 else { throw posixFailure() }
    }

    private func openPrivateDirectory(for url: URL) throws -> Int32 {
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixFailure() }
        do {
            _ = try protect(directory, type: mode_t(S_IFDIR), permissions: Self.ownerDirectoryMode)
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    private func protect(_ descriptor: Int32, type: mode_t, permissions: mode_t) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixFailure() }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == type,
              type != mode_t(S_IFREG) || info.st_nlink == 1
        else {
            throw PrivateFileError.unsafeOwnerOrType
        }
        if info.st_mode & Self.permissionMask != permissions, fchmod(descriptor, permissions) != 0 {
            throw posixFailure()
        }
        return info
    }

    private func posixFailure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
