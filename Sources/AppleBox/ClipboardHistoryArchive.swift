import Foundation

/// One clip as stored in `clipboard_history.json`. The same record reads archives of every version:
/// earlier versions wrote no `id` and kept image bytes inline in `imageData`; current versions write an
/// `id` and keep image bytes in `ClipboardImageStore` under that id, so `imageData` is never written.
/// Keeping a top-level array of records with the earlier keys means an earlier version still decodes a
/// current archive, but it shows image clips without images, and its next save drops the ids that link
/// them to their files. Images are therefore lost when an earlier version saves a current archive.
nonisolated struct StoredClip: Codable, Sendable {
    let id: UUID?
    let content: String
    let timestamp: Date
    let contentType: ClipboardContentType
    let imageData: String?
    let sourceBundleID: String?
}

/// Converts between the in-memory history and its on-disk archive, and migrates archives written by
/// earlier versions. Kept apart from `ClipboardManager` so the file format has one owner.
nonisolated enum ClipboardHistoryArchive {
    /// Result of reading an archive back into memory.
    struct Restored {
        let items: [ClipboardItem]
        /// Every image file the archive names, loaded or not. The sweep keeps these files, and the next
        /// save treats them as on disk, so it deletes the files of clips this load pruned.
        let storedImageIDs: Set<UUID>
        /// True when the archive holds records that must be rewritten: clips without an id, inline image
        /// bytes, duplicates, or clips dropped by the load bounds.
        let needsRewrite: Bool
    }

    /// Writes metadata only; image bytes go to `ClipboardImageStore` before this archive is written.
    static func encode(_ items: [ClipboardItem]) throws -> Data {
        let records = items.map {
            StoredClip(id: $0.id, content: $0.content, timestamp: $0.timestamp, contentType: $0.contentType, imageData: nil, sourceBundleID: $0.sourceBundleID)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(records)
    }

    /// Accepts records of every archive version; see `StoredClip`.
    static func decode(_ data: Data) throws -> [StoredClip] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredClip].self, from: data)
    }

    /// Reads image files only for clips that retention can still keep, so a large or hostile archive
    /// cannot make the load read more than one payload budget of images. Each file is read once to check
    /// it and take its digest, then released, so history holds file references instead of image bytes.
    /// Any read failure other than a missing file throws, so the caller treats the archive as unreadable
    /// and never overwrites it.
    static func restore(_ records: [StoredClip], images: ClipboardImageStore, now: Date = Date()) throws -> Restored {
        let earliest = ClipboardHistoryLimits.cutoff(at: now)
        var items: [ClipboardItem] = []
        var seen = Set<UUID>()
        var imageBytesRead = 0
        for record in records where record.timestamp >= earliest {
            guard items.count < ClipboardHistoryLimits.itemCount, imageBytesRead <= ClipboardHistoryLimits.payloadBudget else { break }
            let id = record.id ?? UUID()
            // A repeated id would make two clips share and later delete one image file.
            guard seen.insert(id).inserted else { continue }
            var image: ClipboardImagePayload?
            if record.contentType == .image, let inline = record.imageData {
                // Inline Base64 from an earlier version stays in memory until the rewrite this load asks
                // for moves it to a file. Text that is not Base64 leaves no image, and retention drops it.
                image = Data(base64Encoded: inline).map(ClipboardImagePayload.init(bytes:))
            } else if record.contentType == .image {
                // An image record without inline bytes or an id, as an earlier version writes after
                // reading a current archive, has no way to reach its file, so it cannot be shown or pasted.
                guard record.id != nil else { continue }
                // A clip whose image file is gone cannot be shown or pasted, so it is dropped. The pool
                // releases each file's bytes before the next read, so the load never holds all of them.
                let stored = try autoreleasepool { () throws -> ClipboardImagePayload? in
                    try images.read(id).map { .stored(bytes: $0, in: images, id: id) }
                }
                guard let stored else { continue }
                image = stored
                imageBytesRead += stored.byteCount
            }
            items.append(ClipboardItem(id: id, content: record.content, timestamp: record.timestamp, contentType: record.contentType, image: image, sourceBundleID: record.sourceBundleID))
        }
        let isCurrentFormat = records.allSatisfy { $0.id != nil && $0.imageData == nil }
        return Restored(
            items: items,
            storedImageIDs: Set(records.filter(isStoredImage).compactMap(\.id)),
            needsRewrite: !isCurrentFormat || items.count != records.count
        )
    }

    /// An image clip in the current format, whose bytes live in a file named by its id.
    private static func isStoredImage(_ record: StoredClip) -> Bool {
        record.contentType == .image && record.id != nil && record.imageData == nil
    }
}
