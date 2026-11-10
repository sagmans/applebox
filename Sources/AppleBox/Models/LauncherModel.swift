import AppKit
import Observation
import OSLog

/// Which result set the launcher shows.
nonisolated enum SearchMode: Sendable {
    case applications
    case clipboard
}

/// One line of feedback for the footer. The severity lets a view style guidance differently from a failure.
nonisolated enum LauncherStatus: Equatable, Sendable {
    case info(String)
    case warning(String)
    case error(String)

    /// Text to display, whatever the severity.
    var message: String {
        switch self {
        case let .info(message), let .warning(message), let .error(message): message
        }
    }
}

/// Mode, query, selection and status for the launcher, in terms of intents rather than views.
///
/// Keys, focus and windows stay with the shell; it translates them into these intents and draws what
/// the models publish.
@Observable
final class LauncherModel {
    /// Which list the launcher shows. Changing it without `switchMode` would leave rows from the other list.
    var mode: SearchMode = .applications
    /// The text the user typed; kept here so Esc and refreshes act on what is on screen.
    var query = ""
    /// Spoken hint on the search field naming the global shortcuts, set by the shell once they are known.
    /// Lives on the model because the field is a view that can only read what the model publishes.
    var searchShortcutHelp = ""
    /// Index of the highlighted row, or nil when focus is on the search field.
    private(set) var selection: Int?

    /// Application results and launching, split out so each list owns its own search.
    let apps: AppSearchModel
    /// Clipboard results, replay and capture state, split out for the same reason.
    let clips: ClipboardModel

    /// Whether the launcher is on screen, because background refreshes only matter while it is.
    private(set) var isPresented = false

    /// Set by the shell; called after a launch, a paste and `escape()` so the shell can close the window.
    @ObservationIgnored var onDismiss: () -> Void = {}

    /// The search a query change started. Awaiting it is how a caller knows the rows are final.
    @ObservationIgnored private(set) var inFlightSearch: Task<Void, Never>?

    /// Whether the search in flight keeps the selection when it publishes; nil when none is pending. A
    /// typed query must never inherit a refresh's preserve flag, or it would keep the old query's row.
    @ObservationIgnored private var pendingSearchPreserves: Bool?
    /// Identifies the newest search, so a superseded search finishing late cannot clear the pending state
    /// that belongs to the search that replaced it.
    @ObservationIgnored private var searchGeneration = 0
    /// Set while a Return waits for a search. A second Return meanwhile is ignored, because two waiters
    /// would each act and a doubled paste is lost. Cleared by cancellation so a later session starts clean.
    @ObservationIgnored private var pendingActivation: UUID?
    @ObservationIgnored private var selectedRowID: AnyHashable?
    @ObservationIgnored private var preservesSelectionOnPublish = false
    @ObservationIgnored private var isResettingResults = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Records why a pointer activation did nothing and which searches were superseded, since neither
    /// shows on screen. Never carries query text, clip content or bundle ids.
    @ObservationIgnored private let logger = Logger(
        subsystem: LogSubsystem.name,
        category: "launcher"
    )

    init(apps: AppSearchModel, clips: ClipboardModel) {
        self.apps = apps
        self.clips = clips
        wireSubmodels()
        observeBackgroundUpdates()
    }

    /// Builds the production object graph from the same seams the window always took, so tests can
    /// substitute the workspace, pasteboard, event source and file system.
    convenience init(
        workspace: WorkspaceProtocol = SystemWorkspace(),
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        eventSource: EventSourceProtocol = SystemEventSource(),
        fileSystem: FileSystemProtocol = SystemFileManager()
    ) {
        self.init(
            apps: AppSearchModel(
                workspace: workspace,
                fileSystem: fileSystem,
                recents: RecentApplicationsStore(fileSystem: fileSystem)
            ),
            clips: ClipboardModel(
                replay: ClipboardReplay(workspace: workspace, pasteboard: pasteboard, eventSource: eventSource)
            )
        )
    }

    /// Isolated so teardown can read the main-actor observer list.
    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Derived state

    /// Rows in the active list, so views and key handling agree on what can be selected.
    var resultCount: Int {
        mode == .clipboard ? clips.rows.count : apps.rows.count
    }

    /// Tells the user which list they are searching, since both modes share one field.
    var placeholder: String {
        mode == .clipboard
            ? DesignTokens.Copy.searchClipboardPlaceholder
            : DesignTokens.Copy.searchApplicationsPlaceholder
    }

    /// Footer guidance for the current mode; launch feedback must not leak into clipboard mode.
    var status: LauncherStatus? {
        switch mode {
        case .clipboard: clips.removalStatus ?? clips.accessStatus
        case .applications: apps.launchStatus
        }
    }

    /// Explains an empty list while leaving the search field in place.
    var emptyMessage: String? {
        guard resultCount == 0 else { return nil }
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case .clipboard: return hasQuery ? DesignTokens.Copy.emptyClipMatches : DesignTokens.Copy.emptyHistory
        case .applications: return hasQuery ? DesignTokens.Copy.emptyApps : nil
        }
    }

    // MARK: - Presentation

    /// Starts a fresh session: previous feedback, query and results never carry over, so each opening
    /// looks the same whatever the user did last time. Call before the window activates, because the
    /// paste target is whichever app has focus at this moment.
    func show(mode requested: SearchMode? = nil) {
        // First, while the app the user copied from still has focus, so a pending copy is credited to it.
        clips.setPanelVisible(true)
        clips.clearRemovalStatus()
        apps.clearLaunchStatus()
        clips.beginReplay()
        enter(requested ?? .applications)
        isPresented = true
    }

    /// Changes mode while the launcher is open. The removal message survives because it describes
    /// history, which a mode flip does not change.
    func switchMode(to newMode: SearchMode) {
        apps.clearLaunchStatus()
        enter(newMode)
    }

    /// The shell calls this when the launcher closes, so nothing in flight can touch a hidden launcher.
    func hide() {
        apps.clearLaunchStatus()
        clips.endReplay()
        clips.setPanelVisible(false)
        cancelWork()
        isPresented = false
    }

    /// Esc clears a typed query before closing, so reopening never shows stale text with a stale row.
    func escape() {
        cancelWork()
        if !query.isEmpty {
            query = ""
            setSelection(nil)
        }
        onDismiss()
    }

    // MARK: - Searching

    /// Applies the field text and searches off the main actor; the rows arrive when the search finishes.
    func setQuery(_ text: String) {
        updateQuery(text)
        startSearch(preservingSelection: false, immediately: false)
    }

    /// Same as `setQuery` but the rows are final on return, for callers that cannot await.
    func setQueryImmediately(_ text: String) {
        updateQuery(text)
        startSearch(preservingSelection: false, immediately: true)
    }

    private func updateQuery(_ text: String) {
        if text != query {
            apps.clearLaunchStatus()
        }
        query = text
    }

    private func startSearch(preservingSelection: Bool, immediately: Bool) {
        inFlightSearch?.cancel()
        inFlightSearch = nil
        // A refresh landing while a typed search is pending joins that search, which goes to the top.
        let preserving = preservingSelection && (pendingSearchPreserves ?? true)
        pendingSearchPreserves = nil
        preservesSelectionOnPublish = preserving
        searchGeneration &+= 1
        let generation = searchGeneration

        let text = query
        let queryLength = text.count
        let started = ContinuousClock.now
        switch mode {
        case .applications where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            apps.resetSearchCache()
            apps.showRecents()
            preservesSelectionOnPublish = false
        case .applications:
            if immediately {
                apps.searchImmediately(text)
                preservesSelectionOnPublish = false
            } else {
                pendingSearchPreserves = preserving
                inFlightSearch = Task { [apps, weak self] in
                    await apps.search(text)
                    self?.searchFinished(generation, queryLength: queryLength, started: started)
                }
            }
        case .clipboard:
            if immediately {
                clips.searchImmediately(text)
                preservesSelectionOnPublish = false
            } else {
                pendingSearchPreserves = preserving
                inFlightSearch = Task { [clips, weak self] in
                    await clips.search(text)
                    self?.searchFinished(generation, queryLength: queryLength, started: started)
                }
            }
        }
    }

    /// Re-runs the current query after the underlying data changed, keeping the user's row if it survives.
    private func refreshPreservingSelection(in refreshedMode: SearchMode) {
        guard isPresented, mode == refreshedMode else { return }
        startSearch(preservingSelection: true, immediately: false)
    }

    /// A superseded search must not clear the flag of the search that replaced it.
    ///
    /// A superseded or cancelled search is logged once, so slow searches that keep being replaced while
    /// the user types can be seen. Counts only: the query text is what the user searched for and never
    /// reaches the log.
    private func searchFinished(_ generation: Int, queryLength: Int, started: ContinuousClock.Instant) {
        guard generation == searchGeneration, !Task.isCancelled else {
            let elapsed = started.duration(to: .now) / .milliseconds(1)
            logger.debug("Search superseded: queryLength=\(queryLength, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
            return
        }
        pendingSearchPreserves = nil
    }

    private func cancelWork() {
        inFlightSearch?.cancel()
        inFlightSearch = nil
        pendingSearchPreserves = nil
        // Hide, Esc and mode changes all pass here, so a waiting Return cannot outlive the state it was for.
        pendingActivation = nil
        apps.invalidatePendingSearch()
        clips.invalidatePendingSearch()
    }

    // MARK: - Selection

    /// Moves the highlight one step at a time. Up from the first row hands focus back to the search
    /// field (nil), and down from the last row stays put, so held keys never wrap unexpectedly.
    func moveSelection(by delta: Int) {
        guard resultCount > 0 else { return }

        let newIndex = (selection ?? -1) + delta
        if newIndex < 0 {
            setSelection(nil)
        } else if newIndex < resultCount {
            setSelection(newIndex)
        }
    }

    /// Highlights a row the user pointed at; anything outside the list means no row.
    func select(_ index: Int) {
        setSelection((0 ..< resultCount).contains(index) ? index : nil)
    }

    private func setSelection(_ index: Int?) {
        selection = index
        selectedRowID = index.flatMap(rowID(at:))
    }

    private func rowID(at index: Int) -> AnyHashable? {
        switch mode {
        case .clipboard: clips.rows.indices.contains(index) ? clips.rows[index].id : nil
        case .applications: apps.rows.indices.contains(index) ? apps.rows[index].id : nil
        }
    }

    private var rowIDs: [AnyHashable] {
        switch mode {
        case .clipboard: clips.rows.map(\.id)
        case .applications: apps.rows.map(\.id)
        }
    }

    // MARK: - Actions

    /// Launches the highlighted app or pastes the highlighted clip, then dismisses on success.
    ///
    /// Return acts on what was typed, so a search still in flight finishes first; the row is then named by
    /// its stable identity at that moment, so later list changes cannot redirect the action.
    func activateSelection() {
        guard pendingSearchPreserves != nil, inFlightSearch != nil else {
            // A waiter may still hold the token for one more hop after its search published. Taking the
            // token here makes that waiter stand down, or this press and the waiter would both act.
            pendingActivation = nil
            activateResolvedSelection()
            return
        }
        guard pendingActivation == nil else { return }
        let token = UUID()
        pendingActivation = token
        let modeAtPress = mode
        Task { [weak self] in
            var awaited: Task<Void, Never>?
            while let self, pendingSearchPreserves != nil, let search = inFlightSearch, search != awaited {
                awaited = search
                await search.value
            }
            guard let self else { return }
            // Cancelled or mode-switched meanwhile means the user moved on; acting now would hit another list.
            guard pendingActivation == token else { return }
            // Every exit releases the guard, or the next Return would be ignored forever.
            pendingActivation = nil
            guard mode == modeAtPress else { return }
            activateResolvedSelection()
        }
    }

    private func activateResolvedSelection() {
        guard let index = selection, index < resultCount, let id = rowID(at: index) else { return }

        switch mode {
        case .clipboard:
            guard let clipID = id as? UUID else { return }
            clips.replay(id: clipID, pasteAutomatically: true) { onDismiss() }
        case .applications:
            guard let bundlePath = id as? String else { return }
            Task { [apps] in _ = await apps.launch(bundlePath: bundlePath) }
        }
    }

    /// Launches the app or pastes the clip the pointer double-clicked, named by its row identity.
    ///
    /// Unlike Return, this never waits for a search in flight: a double-click names a row that is on
    /// screen, and a search landing first would reset the selection to row 0 of a new ranking, which
    /// would paste a different, possibly sensitive clip or open the wrong app. The search is cancelled
    /// so it cannot replace the rows the user clicked. An id that is no longer listed does nothing.
    func activate(id: AnyHashable) {
        cancelWork()
        switch mode {
        case .clipboard:
            guard let clipID = id.base as? UUID,
                  clips.replay(id: clipID, pasteAutomatically: true, dismiss: { onDismiss() })
            else {
                logStaleActivation()
                return
            }
        case .applications:
            guard let bundlePath = id.base as? String, apps.rows.contains(where: { $0.id == bundlePath }) else {
                logStaleActivation()
                return
            }
            Task { [apps] in _ = await apps.launch(bundlePath: bundlePath) }
        }
    }

    /// Only the mode is logged: the id is a clip or a bundle path, and neither may reach the log.
    private func logStaleActivation() {
        logger.info("Pointer activation skipped: row no longer listed, mode=\(String(describing: self.mode), privacy: .public)")
    }

    /// Copies the highlighted clip without pasting. Returns whether the key press was consumed, which in
    /// clipboard mode is always so, because the shortcut is reserved there even with nothing highlighted.
    func copySelection() -> Bool {
        guard mode == .clipboard else { return false }
        if let index = selection, let id = rowID(at: index) as? UUID {
            copyClip(id: id)
        }
        return true
    }

    /// Copies a specific clip without pasting. Menus bind to the id so live capture reordering rows
    /// between opening the menu and choosing an item cannot copy the wrong clip.
    func copyClip(id: UUID) {
        guard mode == .clipboard else { return }
        clips.replay(id: id, pasteAutomatically: false) { onDismiss() }
    }

    /// Removes one clip by id, because the row index can shift under live capture before the call lands.
    func deleteClip(id: UUID) {
        guard mode == .clipboard else { return }
        clips.remove(.item(id))
    }

    /// Wipes the whole history; the caller confirms first, since this cannot be undone.
    func clearHistory() {
        guard mode == .clipboard else { return }
        clips.remove(.all)
    }

    /// Pauses or resumes capture so the user can copy secrets without them entering history.
    func toggleCapture() {
        clips.toggleCapture()
    }

    // MARK: - Dependencies

    /// Supplies the index once it exists, because the launcher opens before indexing finishes; the cache
    /// is reset so results from any earlier service cannot leak in.
    func setSearchService(_ service: SearchService) {
        apps.searchService = service
        service.resetCache()
    }

    /// Supplies the history once it has loaded, for the same reason the launcher cannot wait for it.
    func setClipboardManager(_ manager: ClipboardManager) {
        clips.setManager(manager)
    }

    // MARK: - Fixtures

    /// Shows precomputed application results, for snapshot fixtures that bypass the index.
    func setApplicationResults(_ results: [SearchResult]) {
        mode = .applications
        resetResults { apps.setResults(results) }
    }

    /// Shows precomputed clipboard matches, for snapshot fixtures that bypass the history.
    func setClipboardMatches(_ matches: [ClipboardManager.ClipboardSearchMatch], query: String = "") {
        mode = .clipboard
        resetResults { clips.setMatches(matches, query: query) }
    }

    // MARK: - Internals

    /// Resets the query and results for `newMode` as one step. Both sub-models publish during it, but only
    /// the finished state is announced, so a view never renders a half-switched launcher.
    private func enter(_ newMode: SearchMode) {
        cancelWork()
        mode = newMode
        query = ""
        resetResults {
            switch newMode {
            case .clipboard:
                apps.clear()
                clips.searchImmediately("")
            case .applications:
                clips.clear()
                apps.clear()
                apps.showRecents()
            }
        }
    }

    /// Runs `publish`, then starts selection at the first row once the whole set is in.
    private func resetResults(_ publish: () -> Void) {
        isResettingResults = true
        publish()
        isResettingResults = false
        setSelection(resultCount == 0 ? nil : 0)
    }

    private func wireSubmodels() {
        apps.onPublish = { [weak self] previousCount in self?.resultsPublished(in: .applications, previousCount: previousCount) }
        clips.onPublish = { [weak self] previousCount in self?.resultsPublished(in: .clipboard, previousCount: previousCount) }
        apps.onLaunched = { [weak self] in self?.onDismiss() }
        apps.onRecentsChanged = { [weak self] in
            guard let self, isPresented, mode == .applications,
                  query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            preservesSelectionOnPublish = true
            apps.showRecents()
            // Nothing is published when no index exists yet, and the flag must not outlive this refresh.
            preservesSelectionOnPublish = false
        }
    }

    /// Picks the selection for freshly published rows. A refresh keeps the user's row when it is still
    /// listed, because reordering must not change what Return acts on; a new query starts at the top.
    private func resultsPublished(in publishedMode: SearchMode, previousCount: Int) {
        guard publishedMode == mode, !isResettingResults else { return }

        let preserving = preservesSelectionOnPublish
        preservesSelectionOnPublish = false
        if preserving {
            if previousCount == 0 {
                setSelection(resultCount == 0 ? nil : 0)
            } else if let selectedRowID, let index = rowIDs.firstIndex(of: selectedRowID) {
                setSelection(index)
            } else {
                setSelection(nil)
            }
        } else {
            setSelection(resultCount == 0 ? nil : 0)
        }
    }

    private func observeBackgroundUpdates() {
        let center = NotificationCenter.default
        // Delivered on the main queue, which the compiler cannot see through the Sendable blocks.
        observers = [
            center.addObserver(forName: ClipboardManager.historyDidUpdate, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreservingSelection(in: .clipboard) }
            },
            center.addObserver(forName: ApplicationIndexer.didUpdate, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreservingSelection(in: .applications) }
            },
            center.addObserver(forName: ClipboardManager.readAccessDidChange, object: nil, queue: .main) { [weak self] notification in
                let sender = notification.object as? ClipboardManager
                MainActor.assumeIsolated {
                    guard let self, sender === self.clips.manager else { return }
                    self.clips.refreshCaptureState()
                }
            },
        ]
    }
}
