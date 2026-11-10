import SwiftUI

/// The scrolling result list with one glass selection capsule that glides between rows.
///
/// Rows are plain values; the selection, accessibility and pointer handling live here so a row view only
/// draws content and can stay `Equatable`.
struct ResultsList: View {
    @Bindable var model: LauncherModel

    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.clipImages) private var images

    var body: some View {
        Group {
            if let message = model.emptyMessage {
                ContentUnavailableView(message, systemImage: emptySymbol)
            } else {
                list
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DesignTokens.Identifier.resultsTable)
        .accessibilityLabel(DesignTokens.Copy.resultsLabel)
        .accessibilityHint(DesignTokens.Copy.resultsHelp)
    }

    private var tint: Color {
        model.mode == .clipboard ? DesignTokens.Palette.clipTint : DesignTokens.Palette.appTint
    }

    private var emptySymbol: String {
        model.mode == .clipboard ? DesignTokens.Symbol.emptyClips : DesignTokens.Symbol.emptyApps
    }

    /// Selection moves must retarget at once while a key repeats; a spring on the value does that, and
    /// Reduce Motion swaps it for a short fade.
    private var selectionAnimation: Animation? {
        DesignTokens.motion(DesignTokens.Motion.selection, reduceMotion: reduceMotion)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Metrics.rowSpacing) {
                    switch model.mode {
                    case .applications:
                        ForEach(Array(model.apps.rows.enumerated()), id: \.element.id) { index, row in
                            container(index: index, id: row.id) {
                                AppRow(data: row, isSelected: model.selection == index).equatable()
                            }
                            .accessibilityIdentifier(DesignTokens.Identifier.applicationRow(index))
                            .accessibilityLabel(Self.rowLabel(title: row.name, subtitle: row.location, index: index, count: model.resultCount))
                            .accessibilityHint(Self.rowHint(for: .applications))
                        }
                    case .clipboard:
                        ForEach(Array(model.clips.rows.enumerated()), id: \.element.id) { index, row in
                            container(index: index, id: row.id) {
                                ClipRow(data: row, isSelected: model.selection == index, thumbnail: thumbnail(for: row)).equatable()
                            }
                            .accessibilityIdentifier(DesignTokens.Identifier.clipboardRow(index))
                            .accessibilityLabel(Self.rowLabel(title: row.preview, subtitle: nil, index: index, count: model.resultCount))
                            .accessibilityHint(Self.rowHint(for: .clipboard))
                            .contextMenu { menu(for: row.id) }
                        }
                    }
                }
                .padding(DesignTokens.Metrics.listInset)
            }
            .onChange(of: model.selection) { _, selected in
                guard let selected, let id = rowID(at: selected) else { return }
                // A nil anchor scrolls the least distance, so a held arrow key does not recenter every row.
                proxy.scrollTo(id)
            }
        }
    }

    /// Wraps a row with the selection capsule, pointer handling and accessibility traits.
    private func container(index: Int, id: some Hashable, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = model.selection == index
        return content()
            .background {
                if isSelected {
                    Color.clear
                        .launcherGlass(.regular.tint(tint.opacity(DesignTokens.Palette.selectionTintOpacity)).interactive(), in: .capsule, snapshotFill: DesignTokens.Palette.snapshotSelection)
                        .matchedGeometryEffect(id: DesignTokens.Glass.selectionID, in: selectionSpace)
                }
            }
            .animation(selectionAnimation, value: model.selection)
            .contentShape(Rectangle())
            // With a double-tap gesture present, the single tap waits for the double tap to fail, so selection
            // lands after the system double-click interval; registering the double tap first keeps both working.
            .onTapGesture(count: DesignTokens.Metrics.activationClickCount) {
                model.select(index)
                model.activateSelection()
            }
            .onTapGesture { model.select(index) }
            .id(id)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowID(at index: Int) -> AnyHashable? {
        switch model.mode {
        case .applications: model.apps.rows.indices.contains(index) ? model.apps.rows[index].id : nil
        case .clipboard: model.clips.rows.indices.contains(index) ? model.clips.rows[index].id : nil
        }
    }

    /// Title, subtitle and position in one phrase, in the order a sighted user reads the row. Static and
    /// free of view state so the phrase VoiceOver speaks can be checked without a live accessibility tree.
    static func rowLabel(title: String, subtitle: String?, index: Int, count: Int) -> String {
        [title, subtitle, DesignTokens.Copy.position(index + 1, of: count)]
            .compactMap(\.self)
            .joined(separator: DesignTokens.Copy.labelSeparator)
    }

    /// What Return does on a row, which depends on the list. Static for the same reason as the label.
    static func rowHint(for mode: SearchMode) -> String {
        mode == .clipboard ? DesignTokens.Copy.clipRowHint : DesignTokens.Copy.applicationRowHint
    }

    /// Only image clips need content from the history; looking up text clips would be wasted work per row.
    private func thumbnail(for row: ClipRowData) -> NSImage? {
        guard row.kind == .image, let item = model.clips.item(id: row.id) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? DesignTokens.Metrics.fallbackBackingScale
        return images.thumbnail(for: item, pixelSize: DesignTokens.Metrics.thumbnailSize * scale)
    }

    /// Menu items bind to the clip id so a live history update cannot retarget them to another row.
    @ViewBuilder
    private func menu(for id: UUID) -> some View {
        Button(DesignTokens.Copy.copyClip) { model.copyClip(id: id) }
        Button(DesignTokens.Copy.deleteClip) { model.deleteClip(id: id) }
        Button(DesignTokens.Copy.clearHistoryMenu) {
            ClearHistoryPrompt.present(for: model, over: ClearHistoryPrompt.launcherWindow)
        }
    }
}
