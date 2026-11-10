import AppKit

/// Loaded off the main thread by `AppIconCache`, so providers must be nonisolated and thread-safe.
nonisolated protocol AppIconProviding: Sendable {
    func icon(forBundlePath: String) -> NSImage
}

nonisolated struct SystemAppIconProvider: AppIconProviding {
    func icon(forBundlePath: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: forBundlePath)
    }
}

/// Icons load on `loadQueue`, so the type opts out of default main-actor isolation.
/// `@unchecked Sendable` is safe because `inFlight` is only touched through `inFlightQueue`, and the
/// remaining properties are immutable or NSCache, which is documented as thread-safe.
final nonisolated class AppIconCache: @unchecked Sendable {
    private let loader: AppIconProviding
    private let cache = NSCache<NSString, NSImage>()
    private let loadQueue = DispatchQueue(label: "applebox.icons.load", qos: .utility)

    private let inFlightQueue = DispatchQueue(label: "applebox.icons.inflight")
    private var inFlight: Set<String> = []

    private let placeholder: NSImage

    init(loader: AppIconProviding) {
        self.loader = loader
        placeholder = NSImage(size: NSSize(width: 24, height: 24))
    }

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
                        name: Notification.Name("applebox.appIconCache.didLoad"),
                        object: nil,
                        userInfo: ["bundlePath": bundlePath]
                    )
                }
            }
        }
    }
}
