import SwiftUI

/// Key hints for the current mode, replaced by a status line when there is feedback to give.
///
/// A status wins over hints because it explains why something did not work, and the hints would be
/// stale guidance at that moment.
struct FooterBar: View {
    @Bindable var model: LauncherModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Metrics.hintGroupSpacing) {
            if let status = model.status {
                statusLine(status)
            } else {
                hints
            }
            Spacer(minLength: 0)
        }
        .font(DesignTokens.Typography.footer)
        .padding(.horizontal, DesignTokens.Metrics.barHorizontalPadding)
        .frame(height: DesignTokens.Layout.footerHeight)
        .animation(DesignTokens.motion(DesignTokens.Motion.selection, reduceMotion: reduceMotion), value: model.status)
    }

    private var hasSelection: Bool {
        model.selection != nil
    }

    /// Actions for the highlighted row only; with nothing highlighted Return and copy do nothing, so
    /// advertising them would be wrong. Esc always works.
    @ViewBuilder
    private var hints: some View {
        if hasSelection {
            hint(keys: [.symbol(DesignTokens.Symbol.returnKey)], action: model.mode == .clipboard ? DesignTokens.Copy.actionPaste : DesignTokens.Copy.actionOpen)
            if model.mode == .clipboard {
                hint(keys: [.symbol(DesignTokens.Symbol.optionKey), .symbol(DesignTokens.Symbol.returnKey)], action: DesignTokens.Copy.actionCopy)
            }
        }
        hint(keys: [.text(DesignTokens.Copy.escapeKeyCap, spokenAs: DesignTokens.Copy.escapeKeySpoken)], action: DesignTokens.Copy.actionClose)
    }

    /// A key cap is a symbol where the system has a clear one, and text where it does not: the `escape`
    /// symbol renders as a clock-arrow glyph that does not read as the Esc key.
    private enum KeyCap: Hashable {
        case symbol(String)
        case text(String, spokenAs: String)
    }

    @ViewBuilder
    private func keyCap(_ cap: KeyCap) -> some View {
        switch cap {
        case let .symbol(name):
            Image(systemName: name)
        case let .text(label, spokenAs):
            Text(label).accessibilityLabel(spokenAs)
        }
    }

    private func hint(keys: [KeyCap], action: String) -> some View {
        HStack(spacing: DesignTokens.Metrics.hintSpacing) {
            ForEach(keys, id: \.self) { key in
                keyCap(key)
                    .font(DesignTokens.Typography.keyCap)
                    .padding(.horizontal, DesignTokens.Metrics.keyCapHorizontalPadding)
                    .padding(.vertical, DesignTokens.Metrics.keyCapVerticalPadding)
                    .frame(minWidth: DesignTokens.Metrics.keyCapMinWidth)
                    .background(.quaternary, in: Self.keyCapShape)
                    // The system separator color strengthens itself under Increase Contrast, so the cap
                    // keeps a visible edge without a contrast branch here.
                    .overlay {
                        Self.keyCapShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: DesignTokens.Metrics.hairline)
                    }
            }
            Text(action)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// Solid fill instead of glass: a key cap is a label, and an opaque system fill also stays correct
    /// under Reduce Transparency.
    private static let keyCapShape = RoundedRectangle(cornerRadius: DesignTokens.Metrics.keyCapCornerRadius)

    /// Severity decides color and symbol, so a warning is not mistaken for plain guidance.
    private func statusLine(_ status: LauncherStatus) -> some View {
        let style = Self.style(for: status)
        return HStack(spacing: DesignTokens.Metrics.hintSpacing) {
            Image(systemName: style.symbol)
            Text(status.message)
                .lineLimit(1)
        }
        .foregroundStyle(style.color)
        // The message rises into place so a failure is noticed; Reduce Motion gets a plain fade.
        .transition(reduceMotion ? .opacity : .offset(y: DesignTokens.Motion.errorRise).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private static func style(for status: LauncherStatus) -> (symbol: String, color: Color) {
        switch status {
        case .info: (DesignTokens.Symbol.info, .secondary)
        case .warning: (DesignTokens.Symbol.warning, DesignTokens.Palette.warning)
        case .error: (DesignTokens.Symbol.error, DesignTokens.Palette.error)
        }
    }
}
