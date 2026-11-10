import Foundation
import SwiftUI

/// Single home for values shared by the launcher's models and SwiftUI views, so copy and
/// timing cannot drift between them. Caseless on purpose: it is a namespace for the token groups below.
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
        static let searchApplicationsPlaceholder = "Search applications..."
        static let searchClipboardPlaceholder = "Search clipboard history..."
    }

    /// Durations shared across window and views so launch feedback stays consistent.
    enum Timing {
        /// How long a launch may stay pending before the user sees a timeout message.
        static let launchTimeout: Duration = .seconds(10)
    }

    /// Geometry of the launcher panel and its rows (spec section 4, "Layout"). One home keeps the panel,
    /// the list and the preview agreeing on sizes instead of each view guessing its own.
    enum Layout {
        /// Panel size while searching apps; narrower because there is no preview pane.
        static let appPanelSize = CGSize(width: 680, height: 440)
        /// Panel size in clipboard mode; wider to make room for the preview next to the list.
        static let clipPanelSize = CGSize(width: 760, height: 440)
        /// Width of the clip list, so the preview takes whatever the wider panel adds.
        static let clipListWidth: CGFloat = 300
        /// Corner radius of the glass panel; the content must be clipped to the same value.
        static let cornerRadius: CGFloat = 26
        /// Height of one result row, large enough for a comfortable pointer target.
        static let rowHeight: CGFloat = 48
        /// Side of the app icon and kind badge in a row.
        static let iconSize: CGFloat = 32
        /// Height of the footer that carries status and key hints.
        static let footerHeight: CGFloat = 30
        /// Fraction of the screen height, measured from the top, where the panel's top edge sits. A
        /// third up keeps the panel in the eye line without covering the menu bar.
        static let verticalAnchor: CGFloat = 1.0 / 3.0
    }

    /// Colors for tint, highlight and clip kinds (spec section 4, "Palette"). Semantic names let a theme
    /// change happen here without touching views.
    enum Palette {
        /// Accent of apps mode: amber/honey. Warm on purpose so the launcher reads as one family instead of
        /// borrowing the user's system accent. Each mode keeps a light and a dark value for contrast.
        static let appTint = dynamicColor(light: (0.70, 0.44, 0.12), dark: (0.82, 0.56, 0.22))
        /// Accent of clipboard mode: copper/terracotta, close enough to amber to belong to the family yet
        /// distinct enough that the two modes are told apart at a glance.
        static let clipTint = dynamicColor(light: (0.62, 0.30, 0.16), dark: (0.76, 0.40, 0.24))
        /// Ivory (light) or espresso (dark) wash over the body glass; gives the panel a calm warm base.
        static let surfaceTint = dynamicColor(light: (0.96, 0.91, 0.84), dark: (0.14, 0.10, 0.08))
        /// Match characters on rows that are not selected; dark enough (light) or bright enough (dark) to
        /// reach 4.5:1 against the warm surface where the plain accent would not.
        static let matchText = dynamicColor(light: (0.55, 0.30, 0.06), dark: (1.00, 0.80, 0.45))
        /// Strength of the warm wash over the glass; low enough that the material still shows through.
        static let surfaceTintOpacity: Double = 0.45
        /// Strength of the mode accent on the panel's hairline border; subtle so it signals the mode
        /// without competing with the content.
        static let accentHairlineOpacity: Double = 0.35
        /// Strength of the mode accent in the selection capsule; below full so text on it stays readable.
        static let selectionTintOpacity: Double = 0.55
        /// Strength of the highlight behind matched characters in the preview pane.
        static let matchUnderlayOpacity: Double = 0.18
        /// Color for guidance that needs attention but is not a failure.
        static let warning: Color = .orange
        /// Color for failures.
        static let error: Color = .red

        /// Badge color per clip kind. The switch has no default so a new kind fails to compile here
        /// instead of silently getting a wrong color.
        static func badge(for kind: ClipKind) -> Color {
            switch kind {
            case .text: .gray
            case .link: .blue
            case .code: .purple
            case .color: .pink
            case .image: .green
            case .file: .teal
            }
        }
    }

    /// Animation timing and travel (spec section 4, "Motion"). Springs are `Animation` values and plain
    /// durations are `Double` seconds because SwiftUI animations take seconds; distances are points.
    enum Motion {
        /// Spring for presenting the panel.
        static let open = Animation.spring(response: 0.32, dampingFraction: 0.82)
        /// Scale the panel starts from when opening, so it grows into place.
        static let openScale: CGFloat = 0.96
        /// Fade-out time in seconds; short so dismissal never feels like a wait.
        static let closeDuration = 0.12
        /// Scale the panel shrinks to when closing.
        static let closeScale: CGFloat = 0.98
        /// Spring for moving the selection highlight.
        static let selection = Animation.spring(response: 0.22, dampingFraction: 0.86)
        /// Cross-fade time in seconds when the preview changes.
        static let previewFade = 0.14
        /// Delay in seconds between rows appearing, to suggest order without slowing the list.
        static let rowStagger = 0.012
        /// Rows beyond this count appear together, so long lists do not take long to settle.
        static let rowStaggerLimit = 8
        /// Distance in points a row rises while appearing.
        static let rowRise: CGFloat = 4
        /// Duration in seconds of one row's rise; short so the last staggered row still lands quickly.
        static let rowRiseDuration = 0.18
        /// Distance in points an error message rises while appearing.
        static let errorRise: CGFloat = 6
        /// Fade time in seconds that replaces motion when the user asks for reduced motion.
        static let reducedFade = 0.1
    }

    /// Picks the animation to use, because users who reduce motion must get a plain fade instead of
    /// springs and travel. Returns the animation unchanged otherwise.
    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeInOut(duration: Motion.reducedFade) : animation
    }
}
