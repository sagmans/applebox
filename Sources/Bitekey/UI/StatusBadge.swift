import AppKit

/// Small dot on the menu bar icon that says the menu holds an action the user still needs to take.
/// It is a separate layer-backed view rather than part of the icon, so the logo stays a template
/// image that AppKit tints for light, dark and highlighted menu bars.
final class StatusBadgeView: NSView {
    private enum Metrics {
        /// Large enough to see at a glance, small enough not to cover the logo.
        static let diameter: CGFloat = 6
        /// Pulls the dot into the button's top-right corner, where macOS places badges.
        static let inset: CGFloat = 2
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.diameter, height: Metrics.diameter))
        wantsLayer = true
        layer?.cornerRadius = Metrics.diameter / 2
        // The button's accessibility label carries the meaning, so the dot itself stays silent.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("StatusBadgeView is built in code only")
    }

    /// A layer keeps a fixed color, so the dot is recolored for the menu bar's own appearance, which
    /// can differ from the app's and changes with the wallpaper and dark mode.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The paste toast uses the same warning color, so the dot reads as the same pending task.
            layer?.backgroundColor = NSColor(DesignTokens.Palette.warning).cgColor
        }
    }

    /// Pins the dot to the top-right corner of `button`; autoresizing keeps it there if the item resizes.
    func attach(to button: NSView) {
        setFrameOrigin(NSPoint(
            x: button.bounds.maxX - Metrics.diameter - Metrics.inset,
            y: button.isFlipped ? Metrics.inset : button.bounds.maxY - Metrics.diameter - Metrics.inset
        ))
        autoresizingMask = button.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        button.addSubview(self)
        viewDidChangeEffectiveAppearance()
    }
}
