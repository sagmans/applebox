import AppKit
import CryptoKit

/// Decoded clipboard images are reused across rows and the preview panel so base64 decoding and
/// SHA-256 keying happen once per image, keeping the redesigned views independent of the AppKit window.
final class ClipboardImageCache {
    private let cache = NSCache<NSString, NSImage>()

    func image(for item: ClipboardItem) -> NSImage? {
        guard item.contentType == .image, let base64 = item.imageData else { return nil }

        let key = Self.key(forBase64: base64)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func key(forBase64 base64: String) -> String {
        // Keep keys small even for huge images.
        let digest = SHA256.hash(data: Data(base64.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
