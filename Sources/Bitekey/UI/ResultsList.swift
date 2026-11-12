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
    /// Captions per row index for the result set named by `headersKey`. Derived once per result set, not
    /// per row on each redraw, because a held arrow key redraws the list on every repeat.
    @State private var headers: [String?] = []
    /// The result set `headers` was built for; captions are used only while it matches the shown rows,
    /// so a stale array can never put a caption over the wrong row.
    @State private var headersKey: SectionKey?
    /// Row positions, paired once per published result set; see `IndexedRowsMemo`.
    @State private var appRows = IndexedRowsMemo<AppRowData>()
    @State private var clipRows = IndexedRowsMemo<ClipRowData>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.locale) private var locale
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

    private var selectionOpacity: Double {
        DesignTokens.contrast(
            DesignTokens.Palette.selectionTintOpacity,
            increased: DesignTokens.Palette.increasedSelectionTintOpacity,
            contrast: colorContrast
        )
    }

    private var emptySymbol: String {
        model.mode == .clipboard ? DesignTokens.Symbol.emptyClips : DesignTokens.Symbol.emptyApps
    }

    /// Selection moves must retarget at once while a key repeats; a spring on the value does that, and
    /// Reduce Motion swaps it for a short fade.
    private var selectionAnimation: Animation? {
        DesignTokens.motion(DesignTokens.Motion.selection, reduceMotion: reduceMotion)
    }

    /// Resolved once per list pass and handed to every row, so rows need no environment reads of their own.
    private var selectionStyle: SelectionStyle {
        SelectionStyle(tint: tint, opacity: selectionOpacity, animation: selectionAnimation)
    }

    /// Only the first rows are staggered, so a long list settles as fast as a short one.
    private func arrival(at index: Int) -> AnyTransition {
        guard index < DesignTokens.Motion.rowStaggerLimit else { return .identity }
        let delay = Double(index) * DesignTokens.Motion.rowStagger
        let rise = Animation.easeOut(duration: DesignTokens.Motion.rowRiseDuration).delay(delay)
        // Removal is immediate: rows leaving while the user types must not hold the new results back.
        return DesignTokens.motion(
            .asymmetric(
                insertion: .offset(y: DesignTokens.Motion.rowRise).combined(with: .opacity).animation(rise),
                removal: .identity
            ),
            reduceMotion: reduceMotion
        )
    }

    /// Changes only when the shown rows are replaced. Animating on it, and not on selection, keeps a held
    /// arrow key free of stagger work, and comparing it costs nothing on each redraw.
    private var rowsGeneration: Int {
        model.mode == .clipboard ? model.clips.rowsGeneration : model.apps.rowsGeneration
    }

    private var list: some View {
        // Read once per pass; rows below only index into it.
        let shownHeaders = headersKey == sectionKey ? headers : []
        let style = selectionStyle
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Metrics.rowSpacing) {
                    switch model.mode {
                    case .applications:
                        ForEach(appRows.rows(model.apps.rows, generation: model.apps.rowsGeneration)) { indexed in
                            let index = indexed.index, row = indexed.row
                            if let title = header(at: index, in: shownHeaders) {
                                sectionHeader(title)
                            }
                            container(index: index, id: row.id, style: style) { isSelected in
                                AppRow(data: row, isSelected: isSelected).equatable()
                            }
                            .transition(arrival(at: index))
                            .accessibilityIdentifier(DesignTokens.Identifier.applicationRow(index))
                            .accessibilityLabel(Self.rowLabel(title: row.name, subtitle: row.location, index: index, count: model.resultCount))
                            .accessibilityHint(Self.rowHint(for: .applications))
                        }
                    case .clipboard:
                        ForEach(clipRows.rows(model.clips.rows, generation: model.clips.rowsGeneration)) { indexed in
                            let index = indexed.index, row = indexed.row
                            if let title = header(at: index, in: shownHeaders) {
                                sectionHeader(title)
                            }
                            container(index: index, id: row.id, style: style) { isSelected in
                                ThumbnailClipRow(data: row, isSelected: isSelected, clips: model.clips, reference: referenceDate).equatable()
                            }
                            .opacity(departing.contains(row.id) ? 0 : 1)
                            .frame(height: departing.contains(row.id) ? 0 : nil, alignment: .top)
                            .clipped()
                            .transition(arrival(at: index))
                            .accessibilityIdentifier(DesignTokens.Identifier.clipboardRow(index))
                            // The relative time is on screen under the clip text, so VoiceOver reads it too.
                            .accessibilityLabel(Self.rowLabel(
                                title: row.preview,
                                subtitle: DesignTokens.relativeTime(row.timestamp, reference: referenceDate, locale: locale),
                                index: index,
                                count: model.resultCount
                            ))
                            .accessibilityHint(Self.rowHint(for: .clipboard))
                            .contextMenu { menu(for: row.id) }
                        }
                    }
                }
                .padding(DesignTokens.Metrics.listInset)
                .id(Self.listTopID)
                // Opens the transaction that lets the per-row arrival transitions run; rows that stay
                // keep their place, since only their own transition carries timing.
                .animation(.linear(duration: 0), value: rowsGeneration)
            }
            .background {
                SelectionFollower(model: model) { selected in
                    scroll(to: selected, with: proxy)
                }
            }
            // A finished delete either removed the row already or failed and must show it again; either
            // way nothing stays hidden, even when the failure repeats an earlier message.
            .onChange(of: model.clips.removalsFinished) { _, _ in
                withAnimation(selectionAnimation) { departing.removeAll() }
            }
            .onChange(of: sectionKey, initial: true) { _, key in
                rebuildHeaders(for: key)
            }
        }
    }

    /// Keeps the selected row visible while the keyboard moves it; pointer selection lands on a visible row,
    /// so the extra scroll is a no-op there.
    private func scroll(to selected: Int?, with proxy: ScrollViewProxy) {
        guard let selected, let id = rowID(at: selected) else { return }
        // The first row's header sits above it; scrolling to the row alone would leave the header
        // clipped when the user returns to the top.
        if selected == 0, header(at: 0, in: headers) != nil {
            proxy.scrollTo(Self.listTopID, anchor: .top)
            return
        }
        // A nil anchor scrolls the least distance, so a held arrow key does not recenter every row.
        proxy.scrollTo(id)
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

    /// Names one result set: the mode picks the model and the generation its rows.
    private struct SectionKey: Equatable {
        let mode: SearchMode
        let generation: Int
    }

    private var sectionKey: SectionKey {
        SectionKey(mode: model.mode, generation: rowsGeneration)
    }

    private func header(at index: Int, in titles: [String?]) -> String? {
        titles.indices.contains(index) ? titles[index] : nil
    }

    /// One pass over the rows per result set, with one calendar and one "now", so every caption in the
    /// set agrees on what today is. Buckets count calendar days while a row's relative time counts elapsed
    /// time, so "13 hr. ago" can sit under "Yesterday"; both are true, and the panel is short-lived, so
    /// neither is re-rendered as the clock moves.
    private func rebuildHeaders(for key: SectionKey) {
        headersKey = key
        guard showsSections else {
            headers = []
            return
        }
        switch key.mode {
        case .applications:
            headers = ListSections.appHeaders(for: model.apps.rows)
        case .clipboard:
            var zoned = calendar
            zoned.timeZone = timeZone
            headers = ListSections.clipHeaders(for: model.clips.rows, now: referenceDate ?? Date(), calendar: zoned)
        }
    }

    /// Scroll target of the padded list as a whole, so returning to the first row shows its header and the
    /// list inset instead of stopping at the row's own edge.
    private static let listTopID = "results-list-top"

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

    /// Wraps a row with the selection capsule, pointer handling and accessibility traits. The selection is
    /// read inside `SelectableRow`, never here, so building rows does not depend on it.
    private func container(index: Int, id: some Hashable, style: SelectionStyle, @ViewBuilder content: @escaping (Bool) -> some View) -> some View {
        SelectableRow(
            flag: model.rowSelection.flag(at: index),
            style: style,
            namespace: selectionSpace,
            onSelect: { model.select(index) },
            // The row acts by its id, not the selection, so a search landing meanwhile cannot redirect it.
            onActivate: {
                model.select(index)
                model.activate(id: AnyHashable(id))
            },
            content: content
        )
        .id(id)
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
