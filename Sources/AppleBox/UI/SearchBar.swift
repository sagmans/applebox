import SwiftUI

/// The query field with the mode symbol, result count and capture control.
///
/// Focus is requested on appear and whenever the panel becomes key: the panel is reused between
/// openings, so appearing once is not enough to put the caret in the field every time.
struct SearchBar: View {
    @Bindable var model: LauncherModel

    @FocusState private var isFocused: Bool
    /// Bumped per failed launch; the shake restarts on every change, including repeated identical failures.
    @State private var shakeCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        model.mode == .clipboard ? DesignTokens.Palette.clipTint : DesignTokens.Palette.appTint
    }

    /// Rest, left, right, rest: three steps that end where the field began.
    private static let shakeOffsets: [CGFloat] = [0, -DesignTokens.Motion.shakeDistance, DesignTokens.Motion.shakeDistance, 0]

    private var modeSymbol: String {
        model.mode == .clipboard ? DesignTokens.Symbol.clipMode : DesignTokens.Symbol.appMode
    }

    /// Routes edits through the model's intent so searching starts off the main actor, instead of writing
    /// the stored property, which would change the text without searching.
    private var query: Binding<String> {
        Binding(get: { model.query }, set: { model.setQuery($0) })
    }

    var body: some View {
        HStack(spacing: DesignTokens.Metrics.inlineSpacing) {
            Image(systemName: modeSymbol)
                .font(DesignTokens.Typography.search)
                .foregroundStyle(tint)
                .frame(width: DesignTokens.Metrics.modeSymbolWidth)
                // The replace effect shows the mode change as a swap; Reduce Motion gets a plain cut.
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            TextField(model.placeholder, text: query)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.search)
                .focused($isFocused)
                // The caret follows the mode accent; the system accent would clash with the warm palette.
                .tint(tint)
                .accessibilityIdentifier(DesignTokens.Identifier.searchField)
                .accessibilityLabel(DesignTokens.Copy.searchFieldLabel)
                .accessibilityHint(model.searchShortcutHelp)
            Text(model.resultCount, format: .number)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
            if model.mode == .clipboard {
                pauseButton
            }
        }
        .padding(.horizontal, DesignTokens.Metrics.barHorizontalPadding)
        .padding(.vertical, DesignTokens.Metrics.searchVerticalPadding)
        .phaseAnimator(Self.shakeOffsets, trigger: shakeCount) { content, offset in
            content.offset(x: reduceMotion ? 0 : offset)
        } animation: { _ in
            .easeInOut(duration: DesignTokens.Motion.shakeStep)
        }
        .onChange(of: model.apps.launchStatus) { _, status in
            // Launch failures belong to apps mode; clipboard errors must not shake the field.
            if model.mode == .applications, case .error = status {
                shakeCount += 1
            }
        }
        .animation(DesignTokens.motion(DesignTokens.Motion.selection, reduceMotion: reduceMotion), value: model.mode)
        .onAppear { isFocused = true }
        // Showing again during the close fade posts no didBecomeKey, so presentation itself refocuses.
        .onChange(of: model.isPresented) { _, presented in
            if presented {
                isFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only the launcher: other windows becoming key must not steal focus into this field.
            if note.object is LauncherPanel {
                isFocused = true
            }
        }
    }

    /// Paused capture is a state the user must notice, so the control turns to the warning color.
    private var pauseButton: some View {
        let paused = model.clips.isPaused
        return Button {
            model.toggleCapture()
        } label: {
            Image(systemName: paused ? DesignTokens.Symbol.resume : DesignTokens.Symbol.pause)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .captureButtonStyle()
        .tint(paused ? DesignTokens.Palette.warning : nil)
        .help(paused ? DesignTokens.Copy.capturePausedHelp : DesignTokens.Copy.captureActiveHelp)
        .accessibilityLabel(paused ? DesignTokens.Copy.resumeCapture : DesignTokens.Copy.pauseCapture)
        .accessibilityHint(paused ? DesignTokens.Copy.capturePausedHelp : DesignTokens.Copy.captureActiveHelp)
        // The field keeps the keyboard; the button is a pointer control so Tab never strands typing.
        .focusable(false)
    }
}
