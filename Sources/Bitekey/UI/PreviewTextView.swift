import AppKit
import SwiftUI

/// Read-only, selectable text for the preview pane.
///
/// A clip can be 256 KiB, so the attributed string is rebuilt only when the clip or its font changes, and
/// a highlight change restyles only the affected ranges. Typing in the search field republishes the model
/// constantly, and re-laying out that much text on every keystroke would stall the field.
struct PreviewTextView: NSViewRepresentable {
    /// Identity of the clip; the cheap key that decides whether the text must be rebuilt.
    let itemID: UUID
    let content: String
    /// Character offsets into `content` that matched the query.
    let matchedIndices: [Int]
    let isMonospaced: Bool
    let tint: Color
    /// Seconds the text takes to fade in when another clip is shown; already reduced for Reduce Motion.
    let fadeDuration: Double

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
        // The clip change fade is a layer transition, which needs a backing layer.
        scrollView.wantsLayer = true
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

    /// The preview's text view. Its copies declare Bitekey as their source, because the panel never
    /// activates the app: without the declaration the history would credit the copy to whichever app is
    /// frontmost behind the panel, and the preview would later show a false "Copied from". The history
    /// stores a copy that names Bitekey with no source, the same rule as for any of its own writes.
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
        /// Highlighted ranges now in the text storage, so a highlight change can restyle only them.
        private var shownRanges: [NSRange] = []

        /// Rebuilds the text only when the clip or its font style changes. A keystroke that changes only
        /// the highlights restyles the old and new match ranges on the text already shown, because
        /// rebuilding a 256 KiB attributed string per keystroke stalls typing. A different clip also
        /// returns to the top; the same clip keeps the user's scroll position while its highlights change.
        func apply(_ view: PreviewTextView) {
            guard let textView, let storage = textView.textStorage else { return }
            let isNewItem = shownID != view.itemID
            let needsRebuild = isNewItem || shownMonospaced != view.isMonospaced
            guard needsRebuild || shownIndices != view.matchedIndices else { return }
            shownIndices = view.matchedIndices
            let ranges = matchRuns(in: view.content, indices: view.matchedIndices)
                .map { NSRange($0.range, in: view.content) }
            let styles = PreviewTextStyles(for: view)

            if needsRebuild {
                // The first clip just appears; only a change from one clip to another cross-fades.
                if isNewItem, shownID != nil {
                    Self.fade(textView.enclosingScrollView, duration: view.fadeDuration)
                }
                shownID = view.itemID
                shownMonospaced = view.isMonospaced
                storage.setAttributedString(NSAttributedString(string: view.content, attributes: styles.base))
                shownRanges = []
            } else if ranges == shownRanges {
                return
            }

            storage.beginEditing()
            for range in shownRanges {
                storage.setAttributes(styles.base, range: range)
            }
            for range in ranges {
                storage.setAttributes(styles.match, range: range)
            }
            storage.endEditing()
            shownRanges = ranges

            if isNewItem {
                textView.scrollToBeginningOfDocument(nil)
            }
        }

        /// Cross-fades the next drawn frame of the text from the previous one, without recreating the
        /// view: a fresh text view per clip would cost more than the 256 KiB rebuild it already does.
        private static func fade(_ view: NSView?, duration: Double) {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = duration
            view?.layer?.add(transition, forKey: kCATransition)
        }
    }
}

/// Attributes of plain and matched preview text. Matches use the same tint and weight as list rows so a
/// highlight means one thing. The soft underlay is kept here only: in a long scrolling body, weight alone
/// is too easy to miss.
private struct PreviewTextStyles {
    let base: [NSAttributedString.Key: Any]
    let match: [NSAttributedString.Key: Any]

    init(for view: PreviewTextView) {
        base = [
            .font: Self.font(weight: DesignTokens.PreviewText.baseWeight, monospaced: view.isMonospaced),
            .foregroundColor: NSColor.labelColor,
        ]
        match = [
            .font: Self.font(weight: DesignTokens.PreviewText.matchWeight, monospaced: view.isMonospaced),
            .foregroundColor: NSColor(view.tint),
            .backgroundColor: NSColor(view.tint.opacity(DesignTokens.Palette.matchUnderlayOpacity)),
        ]
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
