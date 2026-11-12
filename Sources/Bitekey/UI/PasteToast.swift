import SwiftUI

/// What a paste notice tells the user. Drives the icon, its color and how long the notice stays, because
/// a plain confirmation needs a glance while guidance and failures ask the user to act.
enum PasteToastKind {
    case confirmation
    case guidance
    case failure

    /// Short for confirmations so they never linger over the destination app; longer when the user has to
    /// read an instruction before it disappears.
    var lifetime: Duration {
        switch self {
        case .confirmation: PasteToastMetrics.confirmationLifetime
        case .guidance, .failure: PasteToastMetrics.actionLifetime
        }
    }

    var symbol: String {
        switch self {
        case .confirmation: "checkmark.circle.fill"
        case .guidance: "info.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    /// Success follows the launcher accent so it reads as part of the app; the others use the palette's
    /// attention colors so they stand out from a routine confirmation.
    var color: Color {
        switch self {
        case .confirmation: DesignTokens.Palette.appTint
        case .guidance: DesignTokens.Palette.warning
        case .failure: DesignTokens.Palette.error
        }
    }
}

/// Sizes and times of the paste notice; named so the panel and the view agree.
enum PasteToastMetrics {
    /// One second is enough to confirm a copy; longer would linger over the app the user returned to.
    static let confirmationLifetime = Duration.seconds(1)
    /// Two seconds keep the long permission text readable, since the user must act on it.
    static let actionLifetime = Duration.seconds(2)
    /// Caps the width so the longest guidance wraps instead of spanning the screen.
    static let maxTextWidth: CGFloat = 420
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 11
    static let iconSpacing: CGFloat = 9
    /// Fade-out time in seconds; the panel stays ordered in until it finishes.
    static let fadeOut = DesignTokens.Motion.closeDuration
}

/// Observable state the AppKit panel updates, so the SwiftUI view can animate its own fade.
@Observable
final class PasteToastState {
    var message = ""
    var kind = PasteToastKind.confirmation
    var visible = false
    /// Bumped once per shown confirmation. The bounce keys on it, not on visibility, so hiding never
    /// bounces and two notices in a row both bounce.
    var bounces = 0
}

/// The notice itself: a glass capsule in the launcher's warm family. It sits in a panel that never takes
/// focus, so it has no interactive parts.
struct PasteToastView: View {
    let state: PasteToastState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: PasteToastMetrics.iconSpacing) {
            Image(systemName: state.kind.symbol)
                .foregroundStyle(state.kind.color)
                // A bounce on the checkmark confirms the copy; Reduce Motion pins the value so it never bounces.
                .symbolEffect(.bounce, value: reduceMotion ? 0 : state.bounces)
                .font(DesignTokens.Typography.toast)
                .accessibilityHidden(true)
            Text(state.message)
                .font(DesignTokens.Typography.toast)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: PasteToastMetrics.maxTextWidth, alignment: .leading)
                // Full height keeps wrapped text from being truncated.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PasteToastMetrics.horizontalPadding)
        .padding(.vertical, PasteToastMetrics.verticalPadding)
        .fixedSize()
        .background { surface }
        .opacity(state.visible ? 1 : 0)
        .animation(fade, value: state.visible)
        .accessibilityElement(children: .combine)
    }

    /// Reduce Transparency swaps the glass for the solid warm surface, since glass would still show what
    /// is behind it.
    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            Capsule().fill(DesignTokens.Palette.surfaceTint)
        } else {
            Color.clear.launcherGlass(
                .regular.tint(DesignTokens.Palette.surfaceTint.opacity(DesignTokens.Palette.surfaceTintOpacity)),
                in: Capsule()
            )
        }
    }

    private var fade: Animation? {
        DesignTokens.motion(
            state.visible ? DesignTokens.Motion.open : .easeOut(duration: PasteToastMetrics.fadeOut),
            reduceMotion: reduceMotion
        )
    }
}
