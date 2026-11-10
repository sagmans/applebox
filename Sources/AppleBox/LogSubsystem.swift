import Foundation

/// The one subsystem every logger uses, so Console filters on a single name and the fallback cannot
/// differ between files.
nonisolated enum LogSubsystem {
    /// Used when no bundle identifier exists (tests, `swift run`), so those logs still group under the app.
    private static let fallbackName = "com.assagman.applebox"

    static let name = Bundle.main.bundleIdentifier ?? fallbackName
}
