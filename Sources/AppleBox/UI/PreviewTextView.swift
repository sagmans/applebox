import AppKit
import SwiftUI

/// Read-only, selectable text for the preview pane.
///
/// A clip can be 256 KiB, so the attributed string is rebuilt only when the clip, its match offsets or
/// its font change. Typing in the search field republishes the model constantly, and re-laying out that
/// much text on every keystroke would stall the field.
struct PreviewTextView: NSViewRepresentable {
    /// Identity of the clip; the cheap key that decides whether the text must be rebuilt.
    let itemID: UUID
    let content: String
    /// Character offsets into `content` that matched the query.
    let matchedIndices: [Int]
    let isMonospaced: Bool
    let tint: Color

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        // The factory wires size tracking between the scroll view, text view and container, which is easy
        // to get subtly wrong by hand and shows up as text that never wraps or never scrolls.
        let scrollView = SourceDeclaringTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else {
            // Without a text view there is nothing to preview; an empty scroll view fails visibly, not by crashing.
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = DesignTokens.PreviewText.inset
        textView.setAccessibilityIdentifier(DesignTokens.Identifier.previewText)
        textView.setAccessibilityLabel(DesignTokens.Copy.previewLabel)
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    /// The preview's text view. Its copies declare AppleBox as their source, because the panel never
    /// activates the app: without the declaration the history would credit the copy to whichever app is
    /// frontmost behind the panel, and the preview would later show a false "Copied from". The history
    /// stores a copy that names AppleBox with no source, the same rule as for any of its own writes.
    final class SourceDeclaringTextView: NSTextView {
        override func copy(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            let before = pasteboard.changeCount
            super.copy(sender)
            // An empty selection copies nothing; tagging the clipboard then would relabel another app's clip.
            guard pasteboard.changeCount != before, let ownBundleID = Bundle.main.bundleIdentifier else { return }
            pasteboard.addTypes([.clipSource], owner: nil)
            pasteboard.setString(ownBundleID, forType: .clipSource)
        }
    }

    /// Remembers what is displayed so unrelated updates can be skipped.
    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var shownID: UUID?
        private var shownIndices: [Int] = []
        private var shownMonospaced: Bool?

        /// Rebuilds the text only when the clip, offsets or font style differ from what is on screen.
        /// A different clip also returns to the top; the same clip keeps the user's scroll position
        /// while its highlights change.
        func apply(_ view: PreviewTextView) {
            guard let textView else { return }
            let isNewItem = shownID != view.itemID
            guard isNewItem || shownIndices != view.matchedIndices || shownMonospaced != view.isMonospaced else { return }
            shownID = view.itemID
            shownIndices = view.matchedIndices
            shownMonospaced = view.isMonospaced

            textView.textStorage?.setAttributedString(Self.attributedString(for: view))
            if isNewItem {
                textView.scrollToBeginningOfDocument(nil)
            }
        }

        /// Matches use the same tint and weight as list rows so a highlight means one thing. The soft
        /// underlay is kept here only: in a long scrolling body, weight alone is too easy to miss.
        private static func attributedString(for view: PreviewTextView) -> NSAttributedString {
            let font = Self.font(weight: DesignTokens.PreviewText.baseWeight, monospaced: view.isMonospaced)
            let result = NSMutableAttributedString(string: view.content, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
            let matchFont = Self.font(weight: DesignTokens.PreviewText.matchWeight, monospaced: view.isMonospaced)
            let tint = NSColor(view.tint)
            let underlay = NSColor(view.tint.opacity(DesignTokens.Palette.matchUnderlayOpacity))
            for run in matchRuns(in: view.content, indices: view.matchedIndices) {
                result.addAttributes([
                    .font: matchFont,
                    .foregroundColor: tint,
                    .backgroundColor: underlay,
                ], range: NSRange(run.range, in: view.content))
            }
            return result
        }

        /// Derived from the body text style's descriptor rather than a point size, so the pane follows the
        /// same scale as the SwiftUI views; SF Mono is used only for code clips.
        private static func font(weight: NSFont.Weight, monospaced: Bool) -> NSFont {
            let base = NSFont.preferredFont(forTextStyle: DesignTokens.PreviewText.textStyle)
            var descriptor = base.fontDescriptor
            if monospaced, let mono = descriptor.withDesign(.monospaced) {
                descriptor = mono
            }
            descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            // Size zero keeps the descriptor's own size, so no point size is chosen here.
            return NSFont(descriptor: descriptor, size: 0) ?? base
        }
    }
}
