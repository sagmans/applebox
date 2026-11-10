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
    /// Bumped when a clip image finishes decoding in the background, so rows that showed their badge
    /// read the cache again and pick up the thumbnail.
    @State private var imageLoads = 0
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Metrics.rowSpacing) {
                    switch model.mode {
                    case .applications:
                        ForEach(Array(model.apps.rows.enumerated()), id: \.element.id) { index, row in
                            if let title = header(at: index, in: shownHeaders) {
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
                            if let title = header(at: index, in: shownHeaders) {
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
                .animation(.linear(duration: 0), value: rowsGeneration)
            }
            // A finished delete either removed the row already or failed and must show it again; either
            // way nothing stays hidden, even when the failure repeats an earlier message.
            .onReceive(NotificationCenter.default.publisher(for: ClipboardImageCache.didLoad)) { _ in
                imageLoads &+= 1
            }
            .onChange(of: model.clips.removalsFinished) { _, _ in
                withAnimation(selectionAnimation) { departing.removeAll() }
            }
            .onChange(of: sectionKey, initial: true) { _, key in
                rebuildHeaders(for: key)
            }
            .onChange(of: model.selection) { _, selected in
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
            // The row acts by its id, not the selection, so a search landing meanwhile cannot redirect it.
            .onTapGesture(count: DesignTokens.Metrics.activationClickCount) {
                model.select(index)
                model.activate(id: AnyHashable(id))
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
    /// Reads `imageLoads` so a decode finishing later redraws the rows that were waiting for it.
    private func thumbnail(for row: ClipRowData) -> NSImage? {
        _ = imageLoads
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
