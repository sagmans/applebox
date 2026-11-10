import AppKit
import ImageIO

/// What the cache holds for a clip image right now. A view tells "still decoding" from "cannot be
/// decoded", because an empty pane reads as loading while a failure must say so.
nonisolated enum ClipImageLookup {
    case pending
    case ready(NSImage)
    case unavailable
}

/// Decoded clipboard images, shared by rows and the preview so each image is decoded once.
///
/// Keyed by the clip's id, not a hash of its bytes: a clip is immutable, and payloads reach about 10 MB of
/// base64, so hashing them on every lookup would cost more than the lookup saves. Ids are assigned when
/// the archive is decoded at startup, so only a restart gives clips new ids, which costs one more decode.
///
/// Decoding runs on `decodeQueue`, because a base64 payload of that size plus the image decode takes tens
/// of milliseconds, and doing it inside a view's body stalls the open motion and typing. Lookups return
/// at once; `didLoad` tells views to look again. The type opts out of default main-actor isolation for
/// that queue. `@unchecked Sendable` is safe because `inFlight` is only touched through `inFlightQueue`,
/// and the remaining properties are immutable or NSCache, which is documented as thread-safe.
final nonisolated class ClipboardImageCache: @unchecked Sendable {
    /// Posted on the main queue when a decode finishes, whatever its result, so views showing the
    /// pending state can redraw.
    static let didLoad = Notification.Name("applebox.clipboardImageCache.didLoad")

    /// One decode result; the box lets a failed decode be cached too, so it is not retried per redraw.
    private final class Box {
        let image: NSImage?
        init(_ image: NSImage?) {
            self.image = image
        }
    }

    /// Names one decode: the full image and the thumbnail of a clip are separate work.
    private struct Job: Hashable {
        let id: UUID
        let isThumbnail: Bool
    }

    private let full = NSCache<NSUUID, Box>()
    private let thumbnails = NSCache<NSUUID, Box>()
    private let decodeQueue = DispatchQueue(label: "applebox.clipImages.decode", qos: .userInitiated)
    private let inFlightQueue = DispatchQueue(label: "applebox.clipImages.inflight")
    /// Jobs queued or running, so redraws while a decode runs do not queue the same work again.
    private var inFlight: Set<Job> = []

    /// Both caches hold at most one entry per clip the history can keep. More would only keep images of
    /// clips that were already evicted from history, and fewer would re-decode visible rows while scrolling.
    init(countLimit: Int = ClipboardHistoryLimits.itemCount) {
        full.countLimit = countLimit
        thumbnails.countLimit = countLimit
    }

    /// Full-size image for the preview; decoded at most once per clip id.
    func image(for item: ClipboardItem) -> ClipImageLookup {
        guard item.contentType == .image, item.imageData != nil else { return .unavailable }
        if let cached = full.object(forKey: item.id as NSUUID) {
            return cached.image.map(ClipImageLookup.ready) ?? .unavailable
        }
        schedule(Job(id: item.id, isThumbnail: false)) {
            item.imageData.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        }
        return .pending
    }

    /// Small image for a list row, or nil while it decodes or when it cannot be decoded; the row shows
    /// its kind badge then. Decoded straight to thumbnail size, because a 32 pt row must not hold a
    /// multi-megapixel bitmap in memory or pay for decoding one.
    func thumbnail(for item: ClipboardItem, pixelSize: CGFloat) -> NSImage? {
        guard item.contentType == .image, item.imageData != nil else { return nil }
        if let cached = thumbnails.object(forKey: item.id as NSUUID) {
            return cached.image
        }
        schedule(Job(id: item.id, isThumbnail: true)) {
            Self.decodeThumbnail(item: item, pixelSize: pixelSize)
        }
        return nil
    }

    private static func decodeThumbnail(item: ClipboardItem, pixelSize: CGFloat) -> NSImage? {
        guard let data = item.imageData.flatMap({ Data(base64Encoded: $0) }),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func schedule(_ job: Job, decode: @escaping @Sendable () -> NSImage?) {
        let shouldStart = inFlightQueue.sync { inFlight.insert(job).inserted }
        guard shouldStart else { return }
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let cache = job.isThumbnail ? thumbnails : full
            cache.setObject(Box(decode()), forKey: job.id as NSUUID)
            inFlightQueue.sync { _ = self.inFlight.remove(job) }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didLoad, object: nil)
            }
        }
    }
}
