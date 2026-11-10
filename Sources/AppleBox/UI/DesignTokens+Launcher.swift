import AppKit
import Foundation
import SwiftUI

/// Tokens that only the SwiftUI launcher views use. They live beside `DesignTokens` rather than in it
/// so the shared file stays about values both the legacy window and the redesign read.
extension DesignTokens.Copy {
    /// Caption for apps the user opened recently, so an empty query explains why these apps lead.
    static let recent = "Recent"
    /// Footer action names, one per key cap, so the hints say what each key does for the current mode.
    static let actionOpen = "Open"
    static let actionPaste = "Paste"
    static let actionCopy = "Copy"
    static let actionClose = "Close"
    /// Shown instead of a preview image when the stored bytes cannot be decoded, so the pane never looks
    /// like it is still loading.
    static let imageUnavailable = "Image unavailable"
    /// Hint of an application row: what Return does there.
    static let applicationRowHint = "Press Enter to launch this application"
    /// Hint of a clip row: Return pastes the clip and Option-Return copies it (the old window said only copy).
    static let clipRowHint = "Press Enter to paste this item, Option-Enter to copy it to the clipboard"
    /// Name of the results list as a whole, so VoiceOver announces what the rows belong to.
    static let resultsLabel = "Search Results"
    /// Name of the launcher panel.
    static let windowLabel = "AppleBox Launcher"
    /// Purpose of the launcher panel.
    static let windowHelp = "Quick launcher for applications and clipboard history"
    /// Accessibility label of the preview pane as a whole.
    static let previewLabel = "Clip preview"

    /// Key that chooses Cancel in the clear-history sheet: Return, so a repeated press can never erase history.
    static let cancelKeyEquivalent = "\r"

    /// Joins the parts of a row's spoken label with a pause, so VoiceOver reads them as separate phrases.
    static let labelSeparator = ", "

    /// Position of a row in its list, read aloud after the row's text so VoiceOver users know where they are.
    static func position(_ index: Int, of count: Int) -> String {
        "\(index) of \(count)"
    }

    /// Size of a text clip for the preview header.
    static func characterCount(_ count: Int) -> String {
        "\(count) characters"
    }

    /// Size of an image clip for the preview header.
    static func pixelSize(width: Int, height: Int) -> String {
        "\(width) × \(height) pixels"
    }
}

extension DesignTokens.Motion {
    /// Dismissal curve: short ease-out so closing never feels like a wait.
    static let close = Animation.easeOut(duration: closeDuration)
}

extension DesignTokens.Palette {
    /// Strength of the fill behind the link host in the preview header; its own value so retuning match
    /// underlays does not change the link badge.
    static let linkHostOpacity: Double = 0.18
    /// Opaque stand-in for glass in snapshot mode. Fixed sRGB grays keep the references independent of the
    /// display profile and of whatever sits behind the panel (ASG-1279); the light and dark values differ
    /// so text keeps the contrast it has over real glass in each appearance.
    static let snapshotSurface = fixedColor(light: (0.93, 0.93, 0.95), dark: (0.2, 0.2, 0.22))
    /// Stand-in for the selection capsule in snapshot mode; set apart from the surface so the highlighted
    /// row is visible in the references.
    static let snapshotSelection = fixedColor(light: (0.72, 0.8, 0.95), dark: (0.35, 0.45, 0.7))

    /// Snapshot colors are opaque: any transparency would let the host's backdrop leak into the references.
    private static let fixedAlpha: CGFloat = 1

    /// A color that resolves to one of two fixed sRGB values by appearance, so snapshots stay stable.
    private static func fixedColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: fixedAlpha)
        })
    }
}

extension DesignTokens {
    /// Date format of the copy time in the preview header: day and time, no year, because clips are recent.
    static let clipDateFormat = Date.FormatStyle().month().day().hour().minute()

    /// SF Symbol names, centralised so a symbol swap is a one-line change and views hold no string literals.
    enum Symbol {
        /// Mode symbol while searching apps.
        static let appMode = "magnifyingglass"
        /// Mode symbol while browsing clipboard history.
        static let clipMode = "list.clipboard"
        /// Capture control while capture is running (pressing it pauses).
        static let pause = "pause.fill"
        /// Capture control while capture is paused (pressing it resumes).
        static let resume = "play.fill"
        /// Footer key caps.
        static let returnKey = "return"
        static let optionKey = "option"
        static let escapeKey = "escape"
        /// Footer status icons, one per severity.
        static let info = "info.circle"
        static let warning = "exclamationmark.triangle.fill"
        static let error = "xmark.octagon.fill"
        /// Shown when an app icon cannot be produced, so the row keeps its shape.
        static let missingIcon = "app.dashed"
        /// Shown when a clip image cannot be decoded.
        static let missingImage = "photo.badge.exclamationmark"
        /// Empty-state symbols.
        static let emptyApps = "magnifyingglass"
        static let emptyClips = "list.clipboard"
        /// Kind badges, matching `Palette.badge(for:)` one to one.
        static let text = "text.alignleft"
        static let link = "link"
        static let code = "chevron.left.forwardslash.chevron.right"
        static let color = "paintpalette.fill"
        static let image = "photo"
        static let file = "doc"

        /// Badge symbol per clip kind. The switch has no default so a new kind fails to compile here.
        static func badge(for kind: ClipKind) -> String {
            switch kind {
            case .text: text
            case .link: link
            case .code: code
            case .color: color
            case .image: image
            case .file: file
            }
        }
    }

    /// Accessibility identifiers the UI tests and assistive tools find elements by. Kept verbatim from the
    /// legacy window so existing automation keeps working.
    enum Identifier {
        static let window = "AppleBoxWindow"
        static let searchField = "AppleBoxSearchField"
        static let resultsTable = "AppleBoxResultsTable"
        static let previewText = "ClipPreviewText"
        static let previewImage = "ClipPreviewImage"

        static func applicationRow(_ index: Int) -> String {
            "ApplicationRow_\(index)"
        }

        static func clipboardRow(_ index: Int) -> String {
            "ClipboardRow_\(index)"
        }
    }

    /// Names of shared glass and selection geometry, so views that must agree on an id cannot drift.
    enum Glass {
        /// Geometry id of the selection capsule, so it glides between rows instead of fading.
        static let selectionID = "selection"
        /// Glass id of the preview pane, so it separates from and merges into the body.
        static let previewID = "preview"
    }

    /// Spacing and sizes inside the launcher views (spec section 4.5), beyond the geometry in `Layout`.
    enum Metrics {
        /// Horizontal inset of the search bar and footer content from the panel edge.
        static let barHorizontalPadding: CGFloat = 20
        /// Vertical inset of the search bar, which makes the field a comfortable target.
        static let searchVerticalPadding: CGFloat = 14
        /// Gap between inline items such as symbol and text.
        static let inlineSpacing: CGFloat = 12
        /// Tight gap between closely related items such as key caps.
        static let tightSpacing: CGFloat = 6
        /// Inset of the list from the glass edge, so the selection capsule never touches the border.
        static let listInset: CGFloat = 8
        /// Horizontal padding inside a row, inside the selection capsule.
        static let rowHorizontalPadding: CGFloat = 12
        /// Vertical gap between a row's title and subtitle.
        static let rowTextSpacing: CGFloat = 1
        /// Side of the mode symbol; sized to the title font so the field and symbol line up.
        static let modeSymbolWidth: CGFloat = 24
        /// Backing scale assumed for thumbnails when no screen reports one, so they are sharp on Retina.
        static let fallbackBackingScale: CGFloat = 2
        /// Hairline weight of separators.
        static let hairline: CGFloat = 1
        /// Inset of the preview glass from the body edge and the list.
        static let previewInset: CGFloat = 8
        /// Corner radius of the preview glass; smaller than the body so it nests visually.
        static let previewCornerRadius: CGFloat = 18
        /// Inner padding of the preview pane.
        static let previewPadding: CGFloat = 14
        /// Gap between preview header and body.
        static let previewSpacing: CGFloat = 10
        /// Corner radius of images in the preview and rows.
        static let imageCornerRadius: CGFloat = 8
        /// Side of the image thumbnail in a clip row.
        static let thumbnailSize: CGFloat = 32
        /// Padding around a footer key cap's symbol.
        static let keyCapPadding: CGFloat = 5
        /// Gap between a key cap group and its action name.
        static let hintSpacing: CGFloat = 4
        /// Gap between footer hints.
        static let hintGroupSpacing: CGFloat = 16
        /// Number of clicks that activates a row.
        static let activationClickCount = 2
        /// Padding of the host capsule in the preview header.
        static let capsuleHorizontalPadding: CGFloat = 8
        static let capsuleVerticalPadding: CGFloat = 2
        /// Space between rows in the list, so adjacent selection capsules never touch.
        static let rowSpacing: CGFloat = 2
        /// Distance within which glass shapes in the container merge. Zero keeps the preview a separate
        /// shape from the body until a later polish step tunes the morph.
        static let glassMergeSpacing: CGFloat = 0
    }

    /// Typography for the launcher, as text styles so the user's text size setting applies.
    enum Typography {
        /// Weight of matched characters, so a match reads as emphasis and not only as color.
        static let matchWeight = Font.Weight.semibold
        static let search = Font.title2
        static let rowTitle = Font.body
        static let rowSubtitle = Font.caption
        static let badge = Font.title3
        static let caption = Font.caption
        static let footer = Font.caption
        static let previewHeader = Font.caption
    }

    /// Preview text metrics. AppKit text uses `NSFont`, so these are separate from `Typography`.
    enum PreviewText {
        /// Text style the preview font follows, so Dynamic Type-like user settings apply.
        static let textStyle = NSFont.TextStyle.body
        /// Weight of matched characters in the preview, matching the semibold of row matches.
        static let matchWeight = NSFont.Weight.semibold
        /// Weight of unmatched characters.
        static let baseWeight = NSFont.Weight.regular
        /// Space around the text inside the text view, so selection highlights do not touch the edge.
        static let inset = CGSize(width: 4, height: 6)
    }
}
