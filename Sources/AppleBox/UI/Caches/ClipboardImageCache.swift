import AppKit
import ImageIO
import Synchronization

/// What the cache holds for a clip image right now. A view tells "still decoding" from "cannot be
/// decoded", because an empty pane reads as loading while a failure must say so.
nonisolated enum ClipImageLookup {
    case pending
    case ready(ClipPreviewImage)
    case unavailable
}

/// A preview image decoded to the pane's size, with the clip's own size beside it. The header reports the
/// clip's real pixels, and the downsampled bitmap no longer carries them.
nonisolated struct ClipPreviewImage: Sendable {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Decoded clipboard images, shared by rows and the preview so each image is decoded once.
///
/// Keyed by the clip's id, not a hash of its bytes: a clip is immutable, and payloads reach about 10 MB of
/// base64, so hashing them on every lookup would cost more than the lookup saves. Ids are assigned when
/// the archive is decoded at startup, so only a restart gives clips new ids, which costs one more decode.
///
/// Decoding runs on `decodeQueue`, because a base64 payload of that size plus the image decode takes tens
/// of milliseconds, and doing it inside a view's body stalls the open motion and typing. Lookups return
/// at once; `didLoad` tells views to look again. Every image leaves the queue as a decoded bitmap at the
/// size it is drawn: an `NSImage(data:)` defers its decode to the first draw, which put a full-resolution
/// decode of about 150 ms and 56 MB per 5K screenshot on the main thread each time the selection moved.
///
/// Entries leave by count, least recently used first, or when the panel hides (`releaseHidden`), never
/// while a view may still draw them. NSCache is not used: it also purges on system
/// memory pressure, and every purge made the visible rows and the preview miss on their next redraw,
/// decode again, post `didLoad`, and redraw. Under sustained pressure that loop kept the decode thread
/// busy and the preview never kept its image long enough to draw it.
///
/// The type opts out of default main-actor isolation for that queue. `@unchecked Sendable` is safe
/// because all mutable state sits in `state`, a mutex, and NSImage values are only read after decoding.
final nonisolated class ClipboardImageCache: @unchecked Sendable {
    /// Posted on the main queue when a decode finishes, whatever its result, so views showing the
    /// pending state can redraw.
    static let didLoad = Notification.Name("applebox.clipboardImageCache.didLoad")
    /// `didLoad` user-info key holding the decoded clip's `UUID`, so a row redraws only for its own image
    /// instead of every row redrawing for each decode.
    static let clipIDKey = "clipID"

    /// Preview images kept at once. The preview shows one, so a few cover stepping back and forth through
    /// neighbouring clips; each holds a few megabytes at pane size, so more would pin memory nobody sees.
    static let defaultFullLimit = 3
    /// Floor for both limits, so a store always keeps the entry a view is drawing.
    private static let minimumLimit = 1
    /// Longest-to-shortest side ratio honoured when sizing a thumbnail decode. Rows fill a square slot, so
    /// the short side must reach the slot size or it is upscaled and blurs; past this ratio a panorama or
    /// a long screenshot would decode a strip many times the slot's width that the crop throws away.
    private static let maximumThumbnailAspect: CGFloat = 8

    /// Names one decode: the full image and the thumbnail of a clip are separate work.
    private struct Job: Hashable {
        let id: UUID
        let isThumbnail: Bool
    }

    /// What one store knows about a clip. `missing` is distinct from a stored failure, so a failed decode
    /// is kept and not retried per redraw.
    private enum Stored<Value: Sendable> {
        case missing
        case decoded(Value?)
    }

    /// Count-bounded least-recently-used map; one per image kind so full images never evict thumbnails.
    private struct LRUStore<Value: Sendable> {
        private var entries: [UUID: (image: Value?, lastUse: UInt64)] = [:]
        private var clock: UInt64 = 0
        let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        /// A hit refreshes recency, so the image a view is drawing is the last to be evicted.
        mutating func get(_ id: UUID) -> Stored<Value> {
            guard let entry = entries[id] else { return .missing }
            clock &+= 1
            entries[id]?.lastUse = clock
            return .decoded(entry.image)
        }

        /// A linear scan for the oldest entry is enough: a store holds at most the history's clip count.
        mutating func put(_ image: Value?, for id: UUID) {
            clock &+= 1
            entries[id] = (image, clock)
            while entries.count > limit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                entries.removeValue(forKey: oldest.key)
            }
        }

        mutating func removeAll() {
            entries.removeAll()
        }
    }

    /// Everything the lookups and the decode queue share, behind one lock so a store and the end of its
    /// in-flight marker are seen together.
    private struct State {
        var full: LRUStore<ClipPreviewImage>
        var thumbnails: LRUStore<NSImage>
        /// Jobs queued or running, so redraws while a decode runs do not queue the same work again.
        var inFlight: Set<Job> = []
        /// Bumped by each release, so a decode that started before it does not put its image back after it.
        var generation: UInt64 = 0
    }

    private let state: Mutex<State>
    private let decodeQueue = DispatchQueue(label: "applebox.clipImages.decode", qos: .userInitiated)

    /// Thumbnails keep one entry per clip the history can hold, so scrolling the whole list never
    /// re-decodes a row; they are small. Full images keep `fullLimit`, see `defaultFullLimit`.
    init(
        fullLimit: Int = ClipboardImageCache.defaultFullLimit,
        thumbnailLimit: Int = ClipboardHistoryLimits.itemCount
    ) {
        state = Mutex(State(
            full: LRUStore(limit: max(Self.minimumLimit, fullLimit)),
            thumbnails: LRUStore(limit: max(Self.minimumLimit, thumbnailLimit))
        ))
    }

    /// Image for the preview, decoded once while the clip stays among the recent ones. Its long side is
    /// at most `maxPixelSize`, the pane's long side in pixels: the pane never draws more, and a full 5K
    /// bitmap would hold about 56 MB per cached clip for nothing.
    ///
    /// The size is fixed by the first lookup; full images are dropped each time the panel hides, so a
    /// move to a screen with another backing scale is picked up on the next open.
    func image(for item: ClipboardItem, maxPixelSize: CGFloat) -> ClipImageLookup {
        guard item.contentType == .image, item.imageData != nil else { return .unavailable }
        switch lookup(id: item.id, in: \.full) {
        case let .decoded(image):
            return image.map(ClipImageLookup.ready) ?? .unavailable
        case .missing:
            schedule(Job(id: item.id, isThumbnail: false), into: \.full) {
                Self.decodePreview(item: item, maxPixelSize: maxPixelSize)
            }
            return .pending
        }
    }

    /// Small image for a list row, or nil while it decodes or when it cannot be decoded; the row shows
    /// its kind badge then. Decoded straight to thumbnail size, because a 32 pt row must not hold a
    /// multi-megapixel bitmap in memory or pay for decoding one.
    func thumbnail(for item: ClipboardItem, pixelSize: CGFloat) -> NSImage? {
        guard item.contentType == .image, item.imageData != nil else { return nil }
        switch lookup(id: item.id, in: \.thumbnails) {
        case let .decoded(image):
            return image
        case .missing:
            schedule(Job(id: item.id, isThumbnail: true), into: \.thumbnails) {
                Self.decodeThumbnail(item: item, slotPixels: pixelSize)
            }
            return nil
        }
    }

    /// Called when the panel has hidden. Full images are large and only the preview draws them, so they
    /// are not kept while nothing is on screen. After a delete or clear, thumbnails go too, so images of
    /// removed clips do not outlive their removal in memory.
    func releaseHidden(clipsWereRemoved: Bool) {
        state.withLock { state in
            state.generation &+= 1
            state.full.removeAll()
            if clipsWereRemoved {
                state.thumbnails.removeAll()
            }
        }
    }

    /// Key paths into `state` mutate the store in place; a get/set pair would copy its dictionary on
    /// every lookup.
    private func lookup<Value: Sendable>(
        id: UUID,
        in store: WritableKeyPath<State, LRUStore<Value>> & Sendable
    ) -> Stored<Value> {
        state.withLock { $0[keyPath: store].get(id) }
    }

    /// The clip's pixel size as shown, so a photo with a rotating EXIF orientation reports the sides the
    /// way the decode, which applies the transform, draws them.
    private static func displayedPixelSize(source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              min(width, height) > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:))
        let isRotated = orientation.map(quarterTurnOrientations.contains) ?? false
        return isRotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// EXIF orientations that turn the image by 90 degrees and so swap its width and height.
    private static let quarterTurnOrientations: Set<CGImagePropertyOrientation> = [
        .leftMirrored, .right, .rightMirrored, .left,
    ]

    /// The decode's long-side size that makes its short side cover a square slot of `slot` pixels. The
    /// thumbnail option bounds the long side only, so a wide or tall image sized by the slot alone comes
    /// out a few pixels thick and blurs when the row crops it to fill.
    private static func fillingPixelSize(source: CGImageSource, slot: CGFloat) -> CGFloat {
        guard let size = displayedPixelSize(source: source) else { return slot }
        let aspect = min(max(size.width, size.height) / min(size.width, size.height), maximumThumbnailAspect)
        return (slot * aspect).rounded(.up)
    }

    /// The clip's image as an ImageIO source; nil when the payload is not base64 or not an image.
    private static func imageSource(item: ClipboardItem) -> CGImageSource? {
        guard let data = item.imageData.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    /// The one decode path for rows and preview. ImageIO decodes straight to the target size, and
    /// `ShouldCacheImmediately` makes it produce the bitmap here on the decode queue; a lazy image would
    /// decode again during the first draw, on the main thread.
    private static func downsample(source: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func decodeThumbnail(item: ClipboardItem, slotPixels: CGFloat) -> NSImage? {
        guard let source = imageSource(item: item) else { return nil }
        return downsample(source: source, maxPixelSize: fillingPixelSize(source: source, slot: slotPixels))
    }

    /// Capped at the clip's own long side, so a small clip is drawn from its real pixels and never from an
    /// enlarged copy.
    private static func decodePreview(item: ClipboardItem, maxPixelSize: CGFloat) -> ClipPreviewImage? {
        guard let source = imageSource(item: item), let size = displayedPixelSize(source: source) else { return nil }
        let longSide = min(max(size.width, size.height), maxPixelSize.rounded(.up))
        guard let image = downsample(source: source, maxPixelSize: longSide) else { return nil }
        return ClipPreviewImage(image: image, pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func schedule<Value: Sendable>(
        _ job: Job,
        into store: WritableKeyPath<State, LRUStore<Value>> & Sendable,
        decode: @escaping @Sendable () -> Value?
    ) {
        let (shouldStart, generation) = state.withLock { ($0.inFlight.insert(job).inserted, $0.generation) }
        guard shouldStart else { return }
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let decoded = decode()
            state.withLock { state in
                state.inFlight.remove(job)
                guard state.generation == generation else { return }
                state[keyPath: store].put(decoded, for: job.id)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didLoad, object: nil, userInfo: [Self.clipIDKey: job.id])
            }
        }
    }
}
