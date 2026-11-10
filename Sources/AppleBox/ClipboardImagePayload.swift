import CryptoKit
import Foundation

/// Raised when an image clip's file no longer holds the bytes that were captured, so a decode or replay
/// never shows or pastes content the user did not copy.
nonisolated enum ClipboardImagePayloadError: Error {
    case contentChanged(expectedBytes: Int, actualBytes: Int)
}

/// An image clip's bytes, kept out of memory once they are in their own file. History holds up to
/// `ClipboardHistoryLimits.payloadBudget` of images for the whole run, while only a decode or a replay needs the bytes, so
/// a clip keeps just its digest and size and reads the file on demand. A new capture holds its bytes in
/// memory only until the next save has written them to `ClipboardImageStore`.
nonisolated struct ClipboardImagePayload: Sendable {
    private enum Storage: Sendable {
        /// Captured, not yet written; also any clip read from an archive that still held images inline.
        case inMemory(Data)
        /// Written to `store` under the clip's id, so the bytes are read from there each time.
        case stored(ClipboardImageStore, UUID)
    }

    private let storage: Storage
    /// Size of the original bytes. Retention costs a clip by it, so an image file is never read to decide
    /// whether a clip stays.
    let byteCount: Int
    /// SHA-256 of the original bytes. The duplicate check compares it instead of megabytes of payload,
    /// and a read checks the file against it.
    private let digest: Data

    init(bytes: Data) {
        storage = .inMemory(bytes)
        byteCount = bytes.count
        digest = Self.digest(of: bytes)
    }

    private init(storage: Storage, byteCount: Int, digest: Data) {
        self.storage = storage
        self.byteCount = byteCount
        self.digest = digest
    }

    /// Payload for bytes already in `store`. The caller has just read them, so the digest describes the
    /// file as it is now, and the bytes can be released.
    static func stored(bytes: Data, in store: ClipboardImageStore, id: UUID) -> Self {
        Self(storage: .stored(store, id), byteCount: bytes.count, digest: digest(of: bytes))
    }

    /// The same image after its bytes were written to `store`, so the in-memory copy can be released.
    func storedCopy(in store: ClipboardImageStore, id: UUID) -> Self {
        Self(storage: .stored(store, id), byteCount: byteCount, digest: digest)
    }

    /// True while only memory holds the bytes, so a save knows it must write them.
    var isInMemory: Bool {
        if case .inMemory = storage {
            return true
        }
        return false
    }

    /// Size plus digest identify the bytes; comparing the payloads themselves cost a full scan per copy.
    func hasSameBytes(as other: Self) -> Bool {
        byteCount == other.byteCount && digest == other.digest
    }

    /// The original bytes, read from the image file when they are no longer in memory. Nil means the file
    /// or its folder is gone. A file whose bytes differ from the capture throws, so a replay never pastes,
    /// and a preview never shows, an image the user did not copy.
    func bytes() throws -> Data? {
        switch storage {
        case let .inMemory(bytes):
            return bytes
        case let .stored(store, id):
            guard let bytes = try store.read(id) else { return nil }
            guard bytes.count == byteCount, Self.digest(of: bytes) == digest else {
                throw ClipboardImagePayloadError.contentChanged(expectedBytes: byteCount, actualBytes: bytes.count)
            }
            return bytes
        }
    }

    /// One log form for every image read failure, so replay and decode logs diagnose alike: the sizes of
    /// a changed file, or the domain and code of an I/O error. Never any image content.
    static func failureSummary(_ error: Error) -> String {
        if case let ClipboardImagePayloadError.contentChanged(expected, actual) = error {
            return "content changed, expected \(expected) bytes, found \(actual)"
        }
        let failure = error as NSError
        return "\(failure.domain) \(failure.code)"
    }

    private static func digest(of bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }
}
