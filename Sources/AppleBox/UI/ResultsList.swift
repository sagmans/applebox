import SwiftUI

/// The scrolling result list with one glass selection capsule that glides between rows.
///
/// Rows are plain values; the selection, accessibility and pointer handling live here so a row view only
/// draws content and can stay `Equatable`.
struct ResultsList: View {
    @Bindable var model: LauncherModel

    @Namespace private var selectionSpace
    /// Clips whose delete was requested. The history confirms asynchronously, so the row collapses at
    /// once instead of waiting for the data to change.
    @State private var departing: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.clipImages) private var images
    @Environment(\.referenceDate) private var referenceDate
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

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

    /// Only the first rows are staggered, so a long list settles as fast as a short one.
    private func arrival(at index: Int) -> AnyTransition {
        guard index < DesignTokens.Motion.rowStaggerLimit else { return .identity }
        if reduceMotion {
            return .opacity.animation(.easeInOut(duration: DesignTokens.Motion.reducedFade))
        }
        let delay = Double(index) * DesignTokens.Motion.rowStagger
        let rise = Animation.easeOut(duration: DesignTokens.Motion.rowRiseDuration).delay(delay)
        // Removal is immediate: rows leaving while the user types must not hold the new results back.
        return .asymmetric(
            insertion: .offset(y: DesignTokens.Motion.rowRise).combined(with: .opacity).animation(rise),
            removal: .identity
        )
    }

    /// Identity of the shown rows. Animating on it, and not on selection, keeps a held arrow key free of
    /// stagger work: moving the highlight never changes the set.
    private var shownIDs: [AnyHashable] {
        model.mode == .clipboard ? model.clips.rows.map(\.id) : model.apps.rows.map(\.id)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Metrics.rowSpacing) {
                    switch model.mode {
                    case .applications:
                        ForEach(Array(model.apps.rows.enumerated()), id: \.element.id) { index, row in
                            if showsSections, let title = ListSections.appHeader(in: model.apps.rows, at: index) {
                                sectionHeader(title)
                            }
                            container(index: index, id: row.id) {
                                AppRow(data: row, isSelected: model.selection == index).equatable()
                            }
                            .transition(arrival(at: index))
                            .accessibilityIdentifier(DesignTokens.Identifier.applicationRow(index))
                            .accessibilityLabel(Self.rowLabel(title: row.name, subtitle: row.location, index: index, count: model.resultCount))
                            .accessibilityHint(Self.rowHint(for: .applications))
                        }
                    case .clipboard:
                        ForEach(Array(model.clips.rows.enumerated()), id: \.element.id) { index, row in
                            if showsSections, let title = clipHeader(at: index) {
                                sectionHeader(title)
                            }
                            container(index: index, id: row.id) {
                                ClipRow(data: row, isSelected: model.selection == index, thumbnail: thumbnail(for: row), reference: referenceDate).equatable()
                            }
                            .opacity(departing.contains(row.id) ? 0 : 1)
                            .frame(height: departing.contains(row.id) ? 0 : nil, alignment: .top)
                            .clipped()
                            .transition(arrival(at: index))
                            .accessibilityIdentifier(DesignTokens.Identifier.clipboardRow(index))
                            .accessibilityLabel(Self.rowLabel(title: row.preview, subtitle: nil, index: index, count: model.resultCount))
                            .accessibilityHint(Self.rowHint(for: .clipboard))
                            .contextMenu { menu(for: row.id) }
                        }
                    }
                }
                .padding(DesignTokens.Metrics.listInset)
                .id(Self.listTopID)
                // Opens the transaction that lets the per-row arrival transitions run; rows that stay
                // keep their place, since only their own transition carries timing.
                .animation(.linear(duration: 0), value: shownIDs)
            }
            .onChange(of: shownIDs) { _, _ in departing.removeAll() }
            .onChange(of: model.status) { _, status in
                // A failed delete leaves the row in the history, so it must come back.
                if case .error = status, !departing.isEmpty {
                    withAnimation(selectionAnimation) { departing.removeAll() }
                }
            }
            .onChange(of: model.selection) { _, selected in
                guard let selected, let id = rowID(at: selected) else { return }
                // The first row's header sits above it; scrolling to the row alone would leave the header
                // clipped when the user returns to the top.
                if selected == 0, showsSections {
                    proxy.scrollTo(Self.listTopID, anchor: .top)
                    return
                }
                // A nil anchor scrolls the least distance, so a held arrow key does not recenter every row.
                proxy.scrollTo(id)
            }
        }
    }

    /// Sections only describe an unfiltered list: a typed query orders rows by match quality, and a day
    /// caption over a ranked list would be wrong. Clips ask the rows themselves, since the live query can
    /// run one async search ahead of them; ranked app rows carry no recents, so the query is enough there.
    private var showsSections: Bool {
        switch model.mode {
        case .applications: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .clipboard: !model.clips.rowsAreRanked
        }
    }

    /// Scroll target of the padded list as a whole, so returning to the first row shows its header and the
    /// list inset instead of stopping at the row's own edge.
    private static let listTopID = "results-list-top"

    /// Buckets count calendar days while the row's relative time counts elapsed time, so "13 hr. ago" can
    /// sit under "Yesterday"; both are true, and the panel is short-lived, so neither is re-rendered as
    /// the clock moves.
    private func clipHeader(at index: Int) -> String? {
        var zoned = calendar
        zoned.timeZone = timeZone
        return ListSections.clipHeader(in: model.clips.rows, at: index, now: referenceDate ?? Date(), calendar: zoned)
    }

    /// A caption between rows. It sits beside the rows in the stack and is not one of them, so selection
    /// indices and the "n of N" VoiceOver positions are untouched; VoiceOver still announces it as a heading.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.Typography.sectionHeader)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Metrics.rowHorizontalPadding)
            .padding(.top, DesignTokens.Metrics.sectionHeaderTopPadding)
            .padding(.bottom, DesignTokens.Metrics.sectionHeaderBottomPadding)
            .accessibilityAddTraits(.isHeader)
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
        Button(DesignTokens.Copy.deleteClip) {
            withAnimation(DesignTokens.motion(.easeInOut(duration: DesignTokens.Motion.rowCollapse), reduceMotion: reduceMotion)) {
                _ = departing.insert(id)
            }
            model.deleteClip(id: id)
        }
        Button(DesignTokens.Copy.clearHistoryMenu) {
            ClearHistoryPrompt.present(for: model, over: ClearHistoryPrompt.launcherWindow)
        }
    }
}
