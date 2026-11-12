import SwiftUI

extension EnvironmentValues {
    /// Replaces every glass surface with a fixed, opaque background.
    ///
    /// Exists for ASG-1279: glass samples what is behind it and follows the display profile, so the color
    /// profile of a snapshot changed from machine to machine and the references never matched. Only tests
    /// set it; it defaults to false, so production always draws glass.
    @Entry var launcherSnapshotMode = false
}

/// Draws a glass surface, or the fixed snapshot background when `launcherSnapshotMode` is on.
///
/// One modifier for all surfaces so the snapshot swap cannot be forgotten on a new one.
private struct GlassSurface<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    /// Fixed fill used instead of the glass in snapshot mode; selection capsules pass a stronger one so
    /// the highlight stays visible in the references.
    let snapshotFill: Color

    @Environment(\.launcherSnapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content.background(snapshotFill, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

/// Gives the pause control the glass style, or a plain bordered one in snapshot mode where glass is off.
private struct CaptureButtonStyle: ViewModifier {
    @Environment(\.launcherSnapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content.buttonStyle(.bordered)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

extension View {
    /// Glass in `shape`, swapped for `snapshotFill` when the environment asks for stable snapshots.
    func launcherGlass(
        _ glass: Glass = .regular,
        in shape: some Shape,
        snapshotFill: Color = DesignTokens.Palette.snapshotSurface
    ) -> some View {
        modifier(GlassSurface(glass: glass, shape: shape, snapshotFill: snapshotFill))
    }

    /// The capture control's button style; see `CaptureButtonStyle`.
    func captureButtonStyle() -> some View {
        modifier(CaptureButtonStyle())
    }
}
