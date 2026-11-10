import Foundation

/// Single home for values shared by the AppKit window and the redesign's SwiftUI views, so copy and
/// timing cannot drift between them. Caseless on purpose: it is a namespace that later tasks extend
/// with layout, palette and motion tokens.
enum DesignTokens {
    /// User-facing strings. Kept byte-for-byte stable (typographic apostrophes and ellipsis included)
    /// because users and tests rely on the exact wording.
    enum Copy {
        static let emptyApps = "No apps found"
        static let emptyClipMatches = "No matching clips"
        static let emptyHistory = "Clipboard history is empty"
        static let copyClip = "Copy to Clipboard"
        static let deleteClip = "Delete Clip"
        static let clearHistoryMenu = "Clear History…"
        static let clearHistoryButton = "Clear History"
        static let cancel = "Cancel"
        static let clearHistoryTitle = "Clear clipboard history?"
        static let clearHistoryExplanation = "This removes saved clips from AppleBox. Your current clipboard stays available."
        static let removalFailed = "Couldn’t remove saved clips. Try again."
        static let pauseCapture = "Pause Capture"
        static let resumeCapture = "Resume Capture"
        static let capturePausedHelp = "Capture is paused. Resume to save new copies."
        static let captureActiveHelp = "Pause saving new clipboard copies."
        static let accessPrompt = "If macOS asks, allow clipboard access to save new copies."
        static let accessDenied = "Clipboard access blocked. Allow AppleBox in System Settings to resume capture."
        static let appMissing = "App was moved or removed. Search again for its new location."
        static let launchFailed = "Couldn’t open this app. Try opening it in Finder."
        static let launchTimedOut = "The app hasn’t opened yet. Try again or open it in Finder."
    }

    /// Durations shared across window and views so launch feedback stays consistent.
    enum Timing {
        /// How long a launch may stay pending before the user sees a timeout message.
        static let launchTimeout: Duration = .seconds(10)
    }
}
