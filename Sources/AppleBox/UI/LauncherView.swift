import SwiftUI

/// Root of the launcher: one glass body that holds search, list and footer, plus a second glass shape
/// for the clip preview in the same container so the two read as one liquid surface.
struct LauncherView: View {
    @Bindable var model: LauncherModel

    @Namespace private var glassSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.launcherSnapshotMode) private var snapshotMode
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
            // A flexible body keeps the search bar and footer fixed whatever the result
            // count; without them an empty state shrinks and the stack centers in the fixed-size panel.
            VStack(spacing: 0) {
                SearchBar(model: model)
                Divider()
                HStack(spacing: 0) {
                    ResultsList(model: model)
                        .frame(width: model.mode == .clipboard ? DesignTokens.Layout.clipListWidth : nil)
                        .frame(maxHeight: .infinity)
                    if model.mode == .clipboard {
                        ClipPreviewPane(model: model)
                            .launcherGlass(.regular, in: .rect(cornerRadius: DesignTokens.Metrics.previewCornerRadius))
                            .glassEffectID(DesignTokens.Glass.previewID, in: glassSpace)
                            .padding(DesignTokens.Metrics.previewInset)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                Divider()
                FooterBar(model: model)
            }
            .frame(width: size.width, height: size.height)
            .launcherGlass(
                .regular.tint(DesignTokens.Palette.surfaceTint.opacity(DesignTokens.Palette.surfaceTintOpacity)),
                in: .rect(cornerRadius: DesignTokens.Layout.cornerRadius)
            )
            // The wash is the same in both modes, so the hairline carries the mode accent.
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Layout.cornerRadius)
                    .strokeBorder(tint.opacity(DesignTokens.Palette.accentHairlineOpacity), lineWidth: DesignTokens.Metrics.hairline)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .opacity(displayedPhase == .shown ? 1 : 0)
        .animation(DesignTokens.motion(DesignTokens.Motion.open, reduceMotion: reduceMotion), value: model.mode)
        .onChange(of: model.isPresented, initial: true) { _, presented in
            present(presented)
        }
    }

    /// Snapshots render the finished state at once; waiting for the open motion would need a run loop
    /// spin that a headless render does not have, and would capture a half-faded frame.
    private var displayedPhase: Phase {
        snapshotMode ? .shown : phase
    }

    /// Reduce Motion drops the scale entirely, leaving only the fade.
    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        return switch displayedPhase {
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
            withAnimation(DesignTokens.motion(DesignTokens.Motion.close, reduceMotion: reduceMotion)) {
                phase = .leaving
            }
        }
    }
}
