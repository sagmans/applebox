import AppKit
import Observation

/// Shapes how a clip is condensed to one list line.
private nonisolated enum ClipPreview {
    /// One line fits roughly this many characters at list width, so the rest only costs layout time.
    static let characterLimit = 100
    /// Whitespace collapsing can shrink text, so more than the limit is read; but a clip can be hundreds of
    /// KiB and the opening list is built on the main actor, so the work must not grow with clip size.
    static let scanLimit = characterLimit * 4
    static let ellipsis = "..."
    static let space = " "
    /// Whitespace that would break a one-line preview, longest first so CRLF counts once.
    static let lineBreaks = ["\r\n", "\n", "\r", "\t"]
}

/// Builds clipboard rows away from the main actor, so classifying and highlighting dozens of clips
/// never delays a keystroke.
nonisolated enum ClipRowBuilder {
    /// Collapses whitespace and truncates, because a row shows one line and the preview pane shows the rest.
    static func preview(of content: String) -> String {
        let isCut = !content.dropFirst(ClipPreview.scanLimit).isEmpty
        let singleLine = ClipPreview.lineBreaks
            .reduce(String(content.prefix(ClipPreview.scanLimit))) { $0.replacingOccurrences(of: $1, with: ClipPreview.space) }
            .split(separator: Character(ClipPreview.space), omittingEmptySubsequences: true)
            .joined(separator: ClipPreview.space)

        // Text dropped before collapsing must still be signalled, or a long clip would look complete.
        return singleLine.count > ClipPreview.characterLimit || isCut
            ? String(singleLine.prefix(ClipPreview.characterLimit)) + ClipPreview.ellipsis
            : singleLine
    }

    /// Match offsets refer to the full clip, so highlights are recomputed against the shortened preview
    /// that is actually drawn.
    static func rows(for matches: [ClipboardManager.ClipboardSearchMatch], query: String) -> [ClipRowData] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches.map { match in
            let preview = preview(of: match.item.content)
            let indices = !match.matchedIndices.isEmpty && !query.isEmpty
                ? FuzzyMatcher.matchWithIndices(query: trimmedQuery, candidate: preview).matchedIndices
                : []
            return ClipRowData(
                id: match.item.id,
                preview: preview,
                kind: ClipKind.classify(match.item),
                timestamp: match.item.timestamp,
                runs: matchRuns(in: preview, indices: indices)
            )
        }
    }
}

/// What a finished clipboard search hands to the main actor.
private nonisolated struct ClipboardSnapshot: Sendable {
    let matches: [ClipboardManager.ClipboardSearchMatch]
    let rows: [ClipRowData]
}

/// Clip results, copy and paste, removal, and capture state.
///
/// Rows are value snapshots. Each search carries a sequence number so a slow result for an older query
/// can never overwrite the rows of a newer one.
@Observable
final class ClipboardModel {
    /// Rows for the current query, ready to render without touching the history.
    private(set) var rows: [ClipRowData] = []

    /// Mirrors the manager because the manager is not observable; refreshed whenever it can change.
    private(set) var isPaused = false
    /// Whether the system lets AppleBox read the pasteboard; drives the recovery guidance, since a blocked
    /// read looks identical to an empty history.
    private(set) var access: ClipboardReadAccess = .allowed

    /// Set when a removal could not be saved, because the clip is still stored and the user must know.
    private(set) var removalStatus: LauncherStatus?

    /// Told the previous row count after rows are replaced, so the owner can fix its selection.
    @ObservationIgnored var onPublish: ((_ previousCount: Int) -> Void)?

    /// Told when status inputs change, so the owner can refresh whatever shows status.
    @ObservationIgnored var onStatusChange: (() -> Void)?

    @ObservationIgnored private(set) var manager: ClipboardManager?
    @ObservationIgnored private let replayer: ClipboardReplay
    /// Full matches back the rows: previews and highlights need the clip text and its unshortened offsets.
    @ObservationIgnored private var matches: [ClipboardManager.ClipboardSearchMatch] = []
    @ObservationIgnored private var sequence = 0

    init(replay: ClipboardReplay) {
        replayer = replay
    }

    /// Set by the shell once history exists, because the UI must be usable before history has loaded.
    func setManager(_ manager: ClipboardManager) {
        self.manager = manager
        refreshCaptureState()
    }

    /// Recovery guidance for blocked clipboard reads; hidden while paused because no read is attempted.
    var accessStatus: LauncherStatus? {
        guard manager != nil, !isPaused else { return nil }
        return switch access {
        case .mayPrompt: .info(DesignTokens.Copy.accessPrompt)
        case .denied: .warning(DesignTokens.Copy.accessDenied)
        case .allowed: nil
        }
    }

    /// Resolves a row to the stored clip, which carries the content rows deliberately omit.
    func item(id: UUID) -> ClipboardItem? {
        matches.first { $0.item.id == id }?.item
    }

    /// Offsets into the full clip text, for highlighting the preview pane.
    func matchedIndices(id: UUID) -> [Int] {
        matches.first { $0.item.id == id }?.matchedIndices ?? []
    }

    // MARK: - Searching

    /// Searches off the main actor and publishes only if no newer search began meanwhile.
    func search(_ query: String) async {
        sequence &+= 1
        let ticket = sequence
        let snapshot = await Self.snapshotOffMain(manager: manager, query: query)
        // A cancelled task returns early with partial output, which must never reach the list.
        guard ticket == sequence, !Task.isCancelled else { return }
        publish(snapshot)
    }

    /// Runs the same search on the caller's actor, for callers that cannot await and need the rows at once.
    func searchImmediately(_ query: String) {
        invalidatePendingSearch()
        publish(Self.snapshot(manager: manager, query: query))
    }

    /// Replaces the results with matches computed elsewhere, such as snapshot fixtures.
    func setMatches(_ newMatches: [ClipboardManager.ClipboardSearchMatch], query: String = "") {
        invalidatePendingSearch()
        publish(ClipboardSnapshot(matches: newMatches, rows: ClipRowBuilder.rows(for: newMatches, query: query)))
    }

    /// Empties the list without announcing it, for callers that are about to publish the next set.
    func clear() {
        invalidatePendingSearch()
        matches = []
        rows = []
    }

    /// Makes any search still in flight stale, so a late result cannot land after the list was reset.
    func invalidatePendingSearch() {
        sequence &+= 1
    }

    private func publish(_ snapshot: ClipboardSnapshot) {
        let previousCount = rows.count
        matches = snapshot.matches
        rows = snapshot.rows
        onPublish?(previousCount)
    }

    private nonisolated static func snapshot(manager: ClipboardManager?, query: String) -> ClipboardSnapshot {
        let found = manager?.searchHistoryWithMatches(query: query) ?? []
        return ClipboardSnapshot(matches: found, rows: ClipRowBuilder.rows(for: found, query: query))
    }

    /// Fuzzy matching and classification scale with history size, so they run on the global executor.
    @concurrent
    private static func snapshotOffMain(manager: ClipboardManager?, query: String) async -> ClipboardSnapshot {
        snapshot(manager: manager, query: query)
    }

    // MARK: - Replay

    /// Records which app had focus, so a paste goes back to it even if the launcher switches modes.
    func beginReplay() {
        replayer.begin()
    }

    /// Releases the recorded paste target, so a later session cannot paste into a stale app.
    func endReplay() {
        replayer.end()
    }

    /// Puts the clip on the pasteboard and, unless copy-only, pastes it into the app that had focus.
    /// Returns false when the clip is gone, for example removed while the menu was open.
    @discardableResult
    func replay(id: UUID, pasteAutomatically: Bool, dismiss: () -> Void) -> Bool {
        guard let item = item(id: id) else { return false }
        replayer.replay(item, pasteAutomatically: pasteAutomatically, dismiss: dismiss)
        return true
    }

    // MARK: - Removal and capture

    /// Removal is confirmed by the store, so a failure is surfaced rather than assumed away.
    func remove(_ removal: ClipboardManager.HistoryRemoval) {
        removalStatus = nil
        onStatusChange?()
        manager?.removeHistory(removal) { [weak self] succeeded in
            guard let self, !succeeded else { return }
            removalStatus = .error(DesignTokens.Copy.removalFailed)
            onStatusChange?()
        }
    }

    /// A stale failure message would follow the user into the next session.
    func clearRemovalStatus() {
        removalStatus = nil
    }

    /// Flips capture through the manager and re-reads state, because the manager is the source of truth
    /// and the footer and menu must show what it actually did.
    func toggleCapture() {
        manager?.toggleCapturePaused()
        refreshCaptureState()
    }

    /// Re-reads state the manager owns. Access changes are announced by notification, but pause state is not,
    /// and callers also need an explicit refresh right after they change either.
    func refreshCaptureState() {
        guard let manager else { return }
        isPaused = manager.isCapturePaused
        access = manager.readAccess
        onStatusChange?()
    }
}
