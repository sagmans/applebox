import SwiftUI

/// Process-wide fallbacks for views that were not given caches. Held once, because a default built
/// inside the environment entry would be a new object on every read and invalidate dependents.
private enum DefaultCaches {
    static let appIcons = AppIconCache(loader: SystemAppIconProvider())
    static let clipImages = ClipboardImageCache()
}

extension EnvironmentValues {
    /// App icons, injected so previews and tests can supply a synchronous provider instead of the
    /// workspace. The default is the production provider, so a view that forgets to inject still works.
    @Entry var appIcons = DefaultCaches.appIcons
    /// Decoded clip images, shared by rows and the preview so each image is decoded once.
    @Entry var clipImages = DefaultCaches.clipImages
    /// Fixed "now" for relative times and day sections. nil in the app, which uses the real time; tests set
    /// it so references do not depend on the day they run.
    @Entry var referenceDate: Date?
}
