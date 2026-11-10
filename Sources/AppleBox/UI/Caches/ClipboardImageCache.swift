import AppKit
import ImageIO

/// Decoded clipboard images, shared by rows and the preview so each image is decoded once.
///
/// Keyed by the clip's id, not a hash of its bytes: a clip is immutable, and payloads reach about 10 MB of
/// base64, so hashing them on every lookup would cost more than the lookup saves. Ids are assigned when
/// the archive is decoded at startup, so only a restart gives clips new ids, which costs one more decode.
final class ClipboardImageCache {
    private let full = NSCache<NSUUID, NSImage>()
    private let thumbnails = NSCache<NSUUID, NSImage>()

    /// Both caches hold at most one entry per clip the history can keep. More would only keep images of
    /// clips that were already evicted from history, and fewer would re-decode visible rows while scrolling.
    init(countLimit: Int = ClipboardHistoryLimits.itemCount) {
        full.countLimit = countLimit
        thumbnails.countLimit = countLimit
    }

    /// Full-size image for the preview; decoded at most once per clip id.
    func image(for item: ClipboardItem) -> NSImage? {
        guard item.contentType == .image, let base64 = item.imageData else { return nil }
        let key = item.id as NSUUID
        if let cached = full.object(forKey: key) {
            return cached
        }
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        full.setObject(image, forKey: key)
        return image
    }

    /// Small image for a list row. Decoded straight to thumbnail size, because a 32 pt row must not hold a
    /// multi-megapixel bitmap in memory or pay for decoding one.
    func thumbnail(for item: ClipboardItem, pixelSize: CGFloat) -> NSImage? {
        guard item.contentType == .image, let base64 = item.imageData else { return nil }
        let key = item.id as NSUUID
        if let cached = thumbnails.object(forKey: key) {
            return cached
        }
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: key)
        return image
    }
}
