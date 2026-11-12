import AppKit

/// The app a clip was copied from, resolved from its bundle id for the preview header.
struct SourceApp: Equatable {
    let name: String
    /// Bundle path, which keys the icon cache.
    let path: String
}

/// Resolves bundle ids to installed apps. Results are memoized because the header re-reads on every
/// selection change and a Launch Services lookup per keystroke would be waste. It lives apart from the
/// icon cache because it answers a different question: which app, not what it looks like.
///
/// Main-actor isolated by default, and that isolation is what makes the shared instance safe to reach
/// from anywhere: every caller is a view on the main actor. It is deliberately not `@unchecked Sendable`,
/// which would add nothing here and would let a future off-main caller race the memo unnoticed.
final class SourceAppResolver {
    static let shared = SourceAppResolver()

    /// Bounds the memo; far more distinct source apps than a 50-clip history can name, so a live session
    /// never evicts one it still shows.
    private static let countLimit = 64
    /// "Not installed" is re-checked after this long, so an app the user installs after copying from it
    /// on another Mac (Universal Clipboard) shows up without restarting Bitekey.
    private static let missingRetryInterval: TimeInterval = 60
    /// Joins a file name and its extension; used to strip ".app" when Finder shows extensions.
    private static let extensionSeparator = "."

    private final class Box {
        let app: SourceApp?
        let resolvedAt: Date
        init(_ app: SourceApp?, resolvedAt: Date) {
            self.app = app
            self.resolvedAt = resolvedAt
        }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = Self.countLimit
    }

    /// nil when the app is gone, so the header simply omits the source instead of showing a stale name.
    func app(forBundleID bundleID: String) -> SourceApp? {
        let now = Date()
        if let known = cache.object(forKey: bundleID as NSString),
           known.app != nil || now.timeIntervalSince(known.resolvedAt) < Self.missingRetryInterval
        {
            return known.app
        }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            SourceApp(name: Self.displayName(of: $0), path: $0.path)
        }
        cache.setObject(Box(resolved, resolvedAt: now), forKey: bundleID as NSString)
        return resolved
    }

    /// The name Finder shows, localized and without the bundle extension, rather than the raw file name,
    /// so "Copied from" matches what the user sees elsewhere in macOS.
    private static func displayName(of url: URL) -> String {
        let shown = FileManager.default.displayName(atPath: url.path)
        let suffix = extensionSeparator + url.pathExtension
        return url.pathExtension.isEmpty || !shown.hasSuffix(suffix) ? shown : String(shown.dropLast(suffix.count))
    }
}
