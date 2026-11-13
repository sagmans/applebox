import AppKit
import Foundation
import SwiftUI

/// Tokens that only the SwiftUI launcher views use. They live beside `DesignTokens` rather than in it
/// so the shared file stays about values the models and the views both read.
extension DesignTokens.Copy {
    /// Section captions. "Recent" explains why the apps the user opened lately lead an empty query, and
    /// "Applications" names the alphabetical rest.
    static let recent = "Recent"
    static let applications = "Applications"
    /// Day buckets of the clip list on an empty query, newest first.
    static let today = "Today"
    static let yesterday = "Yesterday"
    static let earlier = "Earlier"
    /// Spoken prefix of the source app in the preview header, because the icon and name alone do not say
    /// what the app has to do with the clip.
    static func copiedFrom(_ appName: String) -> String {
        "Copied from \(appName)"
    }

    /// Footer action names, one per key cap, so the hints say what each key does for the current mode.
    static let actionOpen = "Open"
    static let actionPaste = "Paste"
    static let actionCopy = "Copy"
    static let actionClose = "Close"
    /// Text on the Esc key cap, because the `escape` SF Symbol does not look like the key.
    static let escapeKeyCap = "esc"
    /// What VoiceOver says for the Esc key cap, since "esc" alone is not a word.
    static let escapeKeySpoken = "Escape"
    /// Shown instead of a preview image when the stored bytes cannot be decoded, so the pane never looks
    /// like it is still loading.
    static let imageUnavailable = "Image unavailable"
    /// Hint of an application row: what Return does there.
    static let applicationRowHint = "Press Enter to launch this application"
    /// Hint of a clip row: Return pastes the clip and Option-Return copies it.
    static let clipRowHint = "Press Enter to paste this item, Option-Enter to copy it to the clipboard"
    /// Name of the results list as a whole, so VoiceOver announces what the rows belong to.
    static let resultsLabel = "Search Results"
    /// Name of the launcher panel.
    static let windowLabel = "Bitekey Launcher"
    /// Purpose of the launcher panel.
    static let windowHelp = "Quick launcher for applications and clipboard history"
    /// Accessibility label of the preview content (text or image) inside the pane.
    static let previewLabel = "Clip preview"
    /// Spoken name and purpose of the preview pane as a whole. Kept verbatim from the earlier AppKit
    /// launcher so VoiceOver users hear what they heard before.
    static let previewPaneLabel = "Clipboard Preview Panel"
    static let previewPaneHelp = "Preview panel for clipboard items"
    /// Spoken help of the results list, naming the keys that move through it. Verbatim from the earlier
    /// launcher for the same reason.
    static let resultsHelp = "Use arrow keys to navigate results, Enter to select."
    /// Spoken name of the search field. Verbatim from the earlier launcher; the placeholder alone names
    /// the list being searched, not the control.
    static let searchFieldLabel = "Search Field"

    /// Joins the parts of a row's spoken label with a pause, so VoiceOver reads them as separate phrases.
    static let labelSeparator = ", "

    /// Position of a row in its list, read aloud after the row's text so VoiceOver users know where they are.
    static func position(_ index: Int, of count: Int) -> String {
        "\(index) of \(count)"
    }

    /// Size of a text clip for the preview header. Grouped by locale so long clips stay readable.
    static func characterCount(_ count: Int) -> String {
        "\(count.formatted()) characters"
    }

    /// Size of an image clip for the preview header.
    static func pixelSize(width: Int, height: Int) -> String {
        "\(width) × \(height) pixels"
    }
}

extension DesignTokens.Motion {
    /// Dismissal curve: short ease-out so closing never feels like a wait.
    static let close = Animation.easeOut(duration: closeDuration)
    /// Cross-fade of the preview when the selected clip changes, so moving through clips reads as one
    /// pane updating rather than content cutting.
    static let previewChange = Animation.easeInOut(duration: previewFade)
}

extension DesignTokens.Palette {
    /// Strength of the fill behind the link host in the preview header; its own value so retuning match
    /// underlays does not change the link badge.
    static let linkHostOpacity: Double = 0.18
    /// Opaque stand-in for glass in snapshot mode. Fixed sRGB violet-tinted tones keep the references independent
    /// of the display profile and of whatever sits behind the panel (ASG-1279); the light and dark values
    /// differ so text keeps the contrast it has over real glass in each appearance.
    static let snapshotSurface = dynamicColor(light: (0.93, 0.91, 0.96), dark: (0.11, 0.10, 0.14))
    /// Opaque stand-in for the violet selection capsule over the surface in snapshot mode; not `appTint`
    /// itself, but set apart from the surface so the highlighted row is visible in the references.
    static let snapshotSelection = dynamicColor(light: (0.65, 0.61, 0.77), dark: (0.24, 0.20, 0.35))

    /// Strength of the glow behind an app icon, tinted with the icon's own average color. Low so it
    /// reads as depth rather than a second highlight competing with the selection capsule.
    static let iconGlowOpacity: Double = 0.45
    /// Strength of the outline around a color swatch, so a swatch close to the panel color keeps an edge.
    static let swatchOutlineOpacity: Double = 0.25
    /// Selection capsule accent under Increase Contrast: the user asked for stronger edges, so the
    /// highlighted row must stand out more than the subtle default allows.
    static let increasedSelectionTintOpacity: Double = 0.8
    /// Panel hairline accent under Increase Contrast, for the same reason.
    static let increasedAccentHairlineOpacity: Double = 0.7

    /// Palette colors are opaque: any transparency would let the host's backdrop leak into the references.
    private static let fixedAlpha: CGFloat = 1

    /// A color that resolves to one of two fixed sRGB values by appearance, so snapshots stay stable and
    /// the palette does not depend on the display profile.
    static func dynamicColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: fixedAlpha)
        })
    }
}

extension DesignTokens {
    /// Picks a strength by the Increase Contrast setting, the contrast counterpart of `motion`, so views
    /// state both values and never branch on the setting themselves.
    static func contrast(_ standard: Double, increased: Double, contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? increased : standard
    }

    /// Key bindings that are behavior, not user copy, so changing wording can never change a key.
    enum Keys {
        /// Key that chooses Cancel in the clear-history sheet: Return, so a repeated press can never erase history.
        static let cancelKeyEquivalent = "\r"
    }

    /// Date format of the copy time in the preview header: day and time, no year, because clips are recent.
    static let clipDateFormat = Date.FormatStyle().month().day().hour().minute()

    /// Short relative time of a clip ("5 min. ago", "yesterday"). `reference` is nil in the app; tests pass a
    /// fixed "now" so references do not change with the day they run. The style has no reference input, so
    /// the date is shifted by the gap between the real and the fixed now, which is exact enough for
    /// minute-level wording.
    static func relativeTime(_ date: Date, reference: Date?, locale: Locale) -> String {
        let shift = reference.map { Date.now.timeIntervalSince($0) } ?? 0
        let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: locale)
        return style.format(date.addingTimeInterval(shift))
    }

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
    /// earlier AppKit launcher so existing automation keeps working.
    enum Identifier {
        static let window = "BitekeyWindow"
        static let searchField = "BitekeySearchField"
        static let resultsTable = "BitekeyResultsTable"
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
        /// Glass id of the panel body, so it resizes as one surface when the mode changes the panel size.
        static let bodyID = "body"
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
        /// Side padding inside a footer key cap, so a glyph does not touch the cap's edge.
        static let keyCapHorizontalPadding: CGFloat = 5
        /// Top and bottom padding inside a key cap; small so caps stay as tall as the hint text line.
        static let keyCapVerticalPadding: CGFloat = 1
        /// Narrowest key cap, so single-glyph caps (⏎, ⌥) read as square keys like menu shortcuts do.
        static let keyCapMinWidth: CGFloat = 20
        /// Corner radius of a key cap: a rounded rectangle like a physical key, not a pill.
        static let keyCapCornerRadius: CGFloat = 4
        /// Gap between a key cap group and its action name.
        static let hintSpacing: CGFloat = 4
        /// Blur radius of the glow behind an app icon.
        static let iconGlowRadius: CGFloat = 7
        /// Side of the source app icon in the preview header; small enough to sit on one line with the
        /// header's callout text.
        static let sourceIconSize: CGFloat = 14
        /// Corner radius of a color swatch in a clip row, matching the badge it replaces.
        static let swatchCornerRadius: CGFloat = 8
        /// Space above a section header, so each group is set apart from the rows before it.
        static let sectionHeaderTopPadding: CGFloat = 8
        /// Space below a section header, small so the caption stays attached to its own group.
        static let sectionHeaderBottomPadding: CGFloat = 2
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

    /// The only place the launcher chooses fonts, so every surface shares one SF Pro scale modeled on
    /// Spotlight and the Finder sidebar. Semantic text styles only: point sizes and the rounded design
    /// would drift from the rest of macOS.
    enum Typography {
        /// Weight of matched characters. Spotlight marks matches by weight alone, so no underline is drawn.
        static let matchWeight = Font.Weight.semibold
        /// Large like Spotlight's field, so the query is the focus of the panel.
        static let search = Font.title
        /// App name or clip text: the one thing the user scans for in a row.
        static let rowTitle = Font.title3
        /// Path or relative time under the title; quieter so it never competes with the title.
        static let rowSubtitle = Font.callout
        /// Group captions styled like Finder sidebar headers: small, bold and secondary.
        static let sectionHeader = Font.subheadline.weight(.semibold)
        /// Date, source app and size above the preview body.
        static let previewHeader = Font.callout
        /// Footer action names and status lines.
        static let footer = Font.callout
        /// Key caps match the footer size; medium weight makes the glyph read as a key face.
        static let keyCap = Font.callout.weight(.medium)
        /// Fixed-width digits so the count does not jitter while typing changes it.
        static let resultCount = Font.callout.monospacedDigit()
        /// Medium weight keeps the short notice legible over any app behind it.
        static let toast = Font.callout.weight(.medium)
        /// Kind badge symbol, sized to sit beside the row title.
        static let badge = Font.title3
    }

    /// Preview text metrics. AppKit text uses `NSFont`, so these are separate from `Typography`.
    enum PreviewText {
        /// Same body style as SwiftUI's `.body`, so the AppKit pane matches the rest of the type scale.
        static let textStyle = NSFont.TextStyle.body
        /// Weight of matched characters in the preview, matching the semibold of row matches.
        static let matchWeight = NSFont.Weight.semibold
        /// Weight of unmatched characters.
        static let baseWeight = NSFont.Weight.regular
        /// Space around the text inside the text view, so selection highlights do not touch the edge.
        static let inset = CGSize(width: 4, height: 6)
    }
}
