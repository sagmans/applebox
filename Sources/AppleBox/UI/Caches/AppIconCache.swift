import AppKit
import SwiftUI

/// Loaded off the main thread by `AppIconCache`, so providers must be nonisolated and thread-safe.
nonisolated protocol AppIconProviding: Sendable {
    /// The icon for the bundle at `forBundlePath`. Called off the main thread, so it must not touch UI state.
    func icon(forBundlePath: String) -> NSImage
}

/// Production provider: asks the workspace, so icons match what Finder shows for the same bundle.
nonisolated struct SystemAppIconProvider: AppIconProviding {
    /// Reads the file icon from the system, which can block on disk, hence the background loading.
    func icon(forBundlePath: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: forBundlePath)
    }
}

/// Icons load on `loadQueue`, so the type opts out of default main-actor isolation.
/// `@unchecked Sendable` is safe because `inFlight` is only touched through `inFlightQueue`, and the
/// remaining properties are immutable or NSCache, which is documented as thread-safe.
final nonisolated class AppIconCache: @unchecked Sendable {
    /// Posted on the main queue when an icon finishes loading, so views showing the placeholder can redraw.
    static let didLoad = Notification.Name("applebox.appIconCache.didLoad")
    /// Key of the bundle path in the load notification's user info.
    static let pathKey = "bundlePath"

    private let loader: AppIconProviding
    private let cache = NSCache<NSString, NSImage>()
    private let loadQueue = DispatchQueue(label: "applebox.icons.load", qos: .utility)

    private let inFlightQueue = DispatchQueue(label: "applebox.icons.inflight")
    private var inFlight: Set<String> = []

    /// Averages are cached apart from icons because they are derived data: a missing average must never
    /// block or re-trigger icon loading. The box lets "icon has no usable color" be cached too.
    private let averages = NSCache<NSString, AverageColorBox>()

    private final class AverageColorBox {
        let color: Color?
        init(_ color: Color?) {
            self.color = color
        }
    }

    private let placeholder: NSImage

    init(loader: AppIconProviding) {
        self.loader = loader
        placeholder = NSImage(size: NSSize(width: 24, height: 24))
    }

    /// Returns at once, so a list never waits on disk: the cached icon, or a placeholder while a background
    /// load runs. Views redraw on `didLoad` to swap the real icon in.
    func icon(forBundlePath bundlePath: String) -> NSImage {
        if let cached = cache.object(forKey: bundlePath as NSString) {
            return cached
        }

        // Tests and previews inject a lightweight icon provider; keep it synchronous for deterministic snapshots.
        if !(loader is SystemAppIconProvider) {
            let icon = loader.icon(forBundlePath: bundlePath)
            cache.setObject(icon, forKey: bundlePath as NSString)
            return icon
        }

        scheduleLoadIfNeeded(bundlePath: bundlePath, notify: true)
        return placeholder
    }

    /// Dominant tone of an icon for the glow behind it. Returns at once: the cached value, or nil while a
    /// background pass computes it, so typing never waits on pixel work. The load notification tells rows
    /// to read again when the value lands.
    func averageColor(forBundlePath bundlePath: String) -> Color? {
        if let cached = averages.object(forKey: bundlePath as NSString) {
            return cached.color
        }
        // Same synchronous path as `icon(forBundlePath:)` for injected providers, so snapshots stay stable.
        if !(loader is SystemAppIconProvider) {
            let color = Self.averageColor(of: loader.icon(forBundlePath: bundlePath))
            averages.setObject(AverageColorBox(color), forKey: bundlePath as NSString)
            return color
        }
        let loaded = cache.object(forKey: bundlePath as NSString)
        guard let loaded else { return nil }
        scheduleAverageIfNeeded(bundlePath: bundlePath, icon: loaded)
        return nil
    }

    private func scheduleAverageIfNeeded(bundlePath: String, icon: NSImage) {
        let key = "avg:" + bundlePath
        let shouldStart = inFlightQueue.sync { inFlight.insert(key).inserted }
        guard shouldStart else { return }
        loadQueue.async { [weak self] in
            guard let self else { return }
            averages.setObject(AverageColorBox(Self.averageColor(of: icon)), forKey: bundlePath as NSString)
            inFlightQueue.sync { _ = self.inFlight.remove(key) }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didLoad, object: nil, userInfo: [Self.pathKey: bundlePath])
            }
        }
    }

    /// Side in pixels of the bitmap an icon is squeezed into; one pixel makes the system's resampling
    /// compute the mean for us.
    private static let averageBitmapSide = 1
    /// Pixels more transparent than this barely contribute to how an icon looks, so a mostly empty icon
    /// yields no glow instead of a muddy one.
    private static let minimumCoverage: CGFloat = 0.2
    private static let bytesPerPixel = 4
    private static let bitsPerComponent = 8
    private static let maxComponent: CGFloat = 255

    /// Mean color of the opaque part of the icon, or nil when it is too transparent to have one.
    private static func averageColor(of icon: NSImage) -> Color? {
        var rect = CGRect(origin: .zero, size: icon.size)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: bytesPerPixel)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: averageBitmapSide,
                height: averageBitmapSide,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerPixel * averageBitmapSide,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: averageBitmapSide, height: averageBitmapSide))
            return true
        }
        let alpha = CGFloat(pixel[3]) / maxComponent
        guard drawn, alpha >= minimumCoverage else { return nil }
        // The bitmap is premultiplied; dividing by alpha recovers the color of the visible pixels.
        let channels = pixel.prefix(3).map { CGFloat($0) / maxComponent / alpha }
        return Color(.sRGB, red: min(channels[0], 1), green: min(channels[1], 1), blue: min(channels[2], 1))
    }

    /// Loads icons ahead of use without notifying: nothing is showing a placeholder for them yet, so a
    /// notification per icon would only make views redraw for no change.
    func prewarm(bundlePaths: [String]) {
        for path in bundlePaths {
            if cache.object(forKey: path as NSString) == nil {
                scheduleLoadIfNeeded(bundlePath: path, notify: false)
            }
        }
    }

    private func scheduleLoadIfNeeded(bundlePath: String, notify: Bool) {
        let shouldStart = inFlightQueue.sync { () -> Bool in
            if inFlight.contains(bundlePath) {
                return false
            }
            inFlight.insert(bundlePath)
            return true
        }

        guard shouldStart else { return }

        loadQueue.async { [weak self] in
            guard let self else { return }
            let icon = loader.icon(forBundlePath: bundlePath)
            cache.setObject(icon, forKey: bundlePath as NSString)

            inFlightQueue.sync {
                _ = self.inFlight.remove(bundlePath)
            }

            if notify {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Self.didLoad,
                        object: nil,
                        userInfo: [Self.pathKey: bundlePath]
                    )
                }
            }
        }
    }
}

/// The app a clip was copied from, resolved from its bundle id for the preview header.
struct SourceApp: Equatable {
    let name: String
    /// Bundle path, which keys the icon cache.
    let path: String
}

/// Resolves bundle ids to installed apps. Results, including "not installed", are memoized because the
/// header re-reads on every selection change and a Launch Services lookup per keystroke would be waste.
final class SourceAppResolver: @unchecked Sendable {
    static let shared = SourceAppResolver()

    private final class Box {
        let app: SourceApp?
        init(_ app: SourceApp?) {
            self.app = app
        }
    }

    private let cache = NSCache<NSString, Box>()

    /// nil when the app is gone, so the header simply omits the source instead of showing a stale name.
    func app(forBundleID bundleID: String) -> SourceApp? {
        if let known = cache.object(forKey: bundleID as NSString) {
            return known.app
        }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            SourceApp(name: $0.deletingPathExtension().lastPathComponent, path: $0.path)
        }
        cache.setObject(Box(resolved), forKey: bundleID as NSString)
        return resolved
    }
}
