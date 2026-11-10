import SwiftUI

/// Root of the launcher: one glass body that holds search, list and footer, plus a second glass shape
/// for the clip preview in the same container so the two read as one liquid surface.
struct LauncherView: View {
    @Bindable var model: LauncherModel

    @Namespace private var glassSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.leaving

    /// Where the panel is in its open/close motion. Kept separate from `isPresented` so opening can start
    /// from the small, transparent state even though the panel is reused and was last left closed.
    private enum Phase {
        case entering
        case shown
        case leaving
    }

    private var tint: Color {
        model.mode == .clipboard ? DesignTokens.Palette.clipTint : DesignTokens.Palette.appTint
    }

    private var size: CGSize {
        model.mode == .clipboard ? DesignTokens.Layout.clipPanelSize : DesignTokens.Layout.appPanelSize
    }

    var body: some View {
        GlassEffectContainer(spacing: DesignTokens.Metrics.glassMergeSpacing) {
            VStack(spacing: 0) {
                SearchBar(model: model)
                Divider()
                HStack(spacing: 0) {
                    ResultsList(model: model)
                        .frame(width: model.mode == .clipboard ? DesignTokens.Layout.clipListWidth : nil)
                    if model.mode == .clipboard {
                        ClipPreviewPane(model: model)
                            .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Metrics.previewCornerRadius))
                            .glassEffectID(DesignTokens.Glass.previewID, in: glassSpace)
                            .padding(DesignTokens.Metrics.previewInset)
                    }
                }
                Divider()
                FooterBar(model: model)
            }
            .frame(width: size.width, height: size.height)
            .glassEffect(
                .regular.tint(tint.opacity(DesignTokens.Palette.glassTintOpacity)),
                in: .rect(cornerRadius: DesignTokens.Layout.cornerRadius)
            )
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .opacity(phase == .shown ? 1 : 0)
        .animation(DesignTokens.motion(DesignTokens.Motion.open, reduceMotion: reduceMotion), value: model.mode)
        .onChange(of: model.isPresented, initial: true) { _, presented in
            present(presented)
        }
    }

    /// Reduce Motion drops the scale entirely, leaving only the fade.
    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        return switch phase {
        case .entering: DesignTokens.Motion.openScale
        case .shown: 1
        case .leaving: DesignTokens.Motion.closeScale
        }
    }

    /// Opening snaps to the start state first, then springs to the end; closing is a short ease-out so
    /// dismissal never feels like a wait.
    private func present(_ presented: Bool) {
        if presented {
            phase = .entering
            Task { @MainActor in
                withAnimation(DesignTokens.motion(DesignTokens.Motion.open, reduceMotion: reduceMotion)) {
                    phase = .shown
                }
            }
        } else {
            let closing: Animation = reduceMotion
                ? .easeInOut(duration: DesignTokens.Motion.reducedFade)
                : .easeOut(duration: DesignTokens.Motion.closeDuration)
            withAnimation(closing) { phase = .leaving }
        }
    }
}
