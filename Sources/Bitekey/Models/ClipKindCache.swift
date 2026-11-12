import Foundation
import Synchronization

/// Kinds of the clips in history, so each clip is classified once instead of on every publish.
///
/// Classification scans up to `ClipKind.classificationScanLimit` characters per clip with many substring
/// checks and a regex, which made every row build cost tens of milliseconds, and rows are built on the
/// main actor when clipboard mode opens.
/// A clip never changes after capture, so its kind is keyed by the clip's id and never goes stale. Ids are
/// assigned when the archive is decoded, so only a restart classifies clips again.
///
/// Rows are built both on the main actor and on the global executor, possibly at the same time, so the
/// entries sit behind a mutex. Classification runs outside the lock so one slow clip never blocks a
/// concurrent build; two builds racing on the same new clip may both classify it, which yields the same
/// kind and is cheaper than serialising every build. Likewise a prune racing an insert can drop a fresh
/// entry or keep a stale one until the next prune; both cost only work, never a wrong kind, because a kind
/// is a pure function of an immutable clip.
///
/// `ClipboardSnapshot` prunes the entries to the ids of each unfiltered search, so clips that expire or
/// are removed do not keep their kinds.
final nonisolated class ClipKindCache: Sendable {
    private let kinds = Mutex<[UUID: ClipKind]>([:])

    /// The stored kind, classifying and storing it first if this clip was not seen yet.
    func kind(for item: ClipboardItem) -> ClipKind {
        if let cached = kinds.withLock({ $0[item.id] }) {
            return cached
        }
        let kind = ClipKind.classify(item)
        kinds.withLock { $0[item.id] = kind }
        return kind
    }

    /// Drops the kinds of clips that left history, so the cache stays bounded by the history itself.
    func retain(only liveIDs: Set<UUID>) {
        kinds.withLock { entries in
            entries = entries.filter { liveIDs.contains($0.key) }
        }
    }
}
