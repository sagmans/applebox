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
            hint(symbols: [DesignTokens.Symbol.returnKey], action: model.mode == .clipboard ? DesignTokens.Copy.actionPaste : DesignTokens.Copy.actionOpen)
            if model.mode == .clipboard {
                hint(symbols: [DesignTokens.Symbol.optionKey, DesignTokens.Symbol.returnKey], action: DesignTokens.Copy.actionCopy)
            }
        }
        hint(symbols: [DesignTokens.Symbol.escapeKey], action: DesignTokens.Copy.actionClose)
    }

    private func hint(symbols: [String], action: String) -> some View {
        HStack(spacing: DesignTokens.Metrics.hintSpacing) {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .padding(DesignTokens.Metrics.keyCapPadding)
                    .launcherGlass(.clear, in: .capsule)
            }
            Text(action)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Severity decides color and symbol, so a warning is not mistaken for plain guidance.
    private func statusLine(_ status: LauncherStatus) -> some View {
        let style = Self.style(for: status)
        return HStack(spacing: DesignTokens.Metrics.hintSpacing) {
            Image(systemName: style.symbol)
            Text(status.message)
                .lineLimit(1)
        }
        .foregroundStyle(style.color)
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
