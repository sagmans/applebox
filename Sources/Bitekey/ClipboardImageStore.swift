import Foundation

/// Keeps each image clip's bytes in its own private file, named by the clip id, so a history save
/// rewrites only small metadata and an unchanged image is never written twice. All access goes through
/// the private-file primitives, so these files keep the archive's owner-only, no-follow guarantees.
/// It is the single place that knows where image bytes live, so a later change that loads them on
/// demand instead of keeping them in memory only has to call `read` at another time.
nonisolated struct ClipboardImageStore: Sendable {
    /// Folder next to the history archive. A separate folder keeps the sweep away from other app files.
    static let directoryName = "clipboard_images"
    /// Most entries one sweep inspects. History holds at most `ClipboardHistoryLimits.itemCount`
    /// images, so a larger listing means leftovers from crashes; the next launch removes the rest.
    private static let sweepListingLimit = 1024
    /// Owner-only, like the archive folder, so other local users cannot list or read clipped images.
    private static let directoryMode = 0o700

    private let directory: URL
    private let fileSystem: FileSystemProtocol

    init(directory: URL, fileSystem: FileSystemProtocol) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    /// Writes are atomic replacements, so a crash leaves either no file or a complete one. The folder is
    /// created on the first image, so a text-only history never gets one.
    func write(_ bytes: Data, for id: UUID) throws {
        if !directoryExists {
            try fileSystem.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: Self.directoryMode])
        }
        try fileSystem.writePrivateFile(bytes, to: url(for: id))
    }

    /// Nil means the file or its folder is gone; the caller then drops that one clip. Reads use the
    /// capture size limit, because no larger image is ever stored and a bigger file was not written here.
    func read(_ id: UUID) throws -> Data? {
        guard directoryExists else { return nil }
        return try fileSystem.readPrivateFile(at: url(for: id), maximumBytes: ClipboardHistoryLimits.imageBytes)
    }

    func remove(_ id: UUID) throws {
        guard directoryExists else { return }
        try fileSystem.removePrivateFile(at: url(for: id))
    }

    /// Removes files that no archived clip references: leftovers of a crash between an image write and
    /// the archive write, or of a clear that could not finish. Only names that are canonical clip ids are
    /// touched, so a file this store did not create is never deleted. One entry that cannot be removed
    /// does not stop the others, because a clear must delete as many clipped images as it can.
    func removeAll(except kept: Set<UUID>) throws {
        guard directoryExists else { return }
        let entries = try fileSystem.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [], limit: Self.sweepListingLimit)
        var firstFailure: Error?
        for entry in entries {
            let name = entry.lastPathComponent
            guard let id = UUID(uuidString: name), id.uuidString == name, !kept.contains(id) else { continue }
            do {
                try remove(id)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw firstFailure
        }
    }

    /// A missing folder means no image was saved yet, or the folder was deleted while the app ran.
    /// Anything else at that path, a link included, still reaches the private-file checks, which reject it.
    var directoryExists: Bool {
        fileSystem.fileExists(atPath: directory.path)
    }

    /// The canonical upper-case UUID string is the only name form, so it cannot contain a path separator.
    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: false)
    }
}
