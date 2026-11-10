import AppKit
import Observation

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

/// What changed, for a shell that cannot observe the models and must update its views by hand.
nonisolated enum LauncherChange: Equatable, Sendable {
    /// Rows were replaced. `preservedSelection` tells whether the user's row was kept, which decides
    /// whether the view should jump back to the top or stay where the user was.
    case results(preservedSelection: Bool)
    /// The footer message or the capture state changed.
    case status
}

/// Mode, query, selection and status for the launcher, in terms of intents rather than views.
///
/// Keys, focus and windows stay with the shell; it translates them into these intents and draws what
/// the models publish.
@Observable
final class LauncherModel {
    var mode: SearchMode = .applications
    var query = ""
    /// Index of the highlighted row, or nil when focus is on the search field.
    private(set) var selection: Int?

    let apps: AppSearchModel
    let clips: ClipboardModel

    /// Whether the launcher is on screen, because background refreshes only matter while it is.
    private(set) var isPresented = false

    /// Set by the shell; called after a launch, a paste and `escape()` so the shell can close the window.
    @ObservationIgnored var onDismiss: () -> Void = {}

    /// Set by shells that cannot observe the models; see `LauncherChange`.
    @ObservationIgnored var onChange: ((LauncherChange) -> Void)?

    /// The search a query change started. Awaiting it is how a caller knows the rows are final.
    @ObservationIgnored private(set) var inFlightSearch: Task<Void, Never>?

    /// The launch an activation started. Awaiting it is how a caller knows the outcome is final.
    @ObservationIgnored private(set) var inFlightLaunch: Task<Void, Never>?

    @ObservationIgnored private var selectedRowID: AnyHashable?
    @ObservationIgnored private var preservesSelectionOnPublish = false
    @ObservationIgnored private var isResettingResults = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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

    var resultCount: Int {
        mode == .clipboard ? clips.rows.count : apps.rows.count
    }

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
        preservesSelectionOnPublish = preservingSelection

        let text = query
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
                inFlightSearch = Task { [apps] in await apps.search(text) }
            }
        case .clipboard:
            if immediately {
                clips.searchImmediately(text)
                preservesSelectionOnPublish = false
            } else {
                inFlightSearch = Task { [clips] in await clips.search(text) }
            }
        }
    }

    /// Re-runs the current query after the underlying data changed, keeping the user's row if it survives.
    private func refreshPreservingSelection(in refreshedMode: SearchMode) {
        guard isPresented, mode == refreshedMode else { return }
        startSearch(preservingSelection: true, immediately: false)
    }

    private func cancelWork() {
        inFlightSearch?.cancel()
        inFlightSearch = nil
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
    func activateSelection() {
        guard let index = selection, index < resultCount else { return }

        switch mode {
        case .clipboard:
            guard let id = rowID(at: index) as? UUID else { return }
            clips.replay(id: id, pasteAutomatically: true) { onDismiss() }
        case .applications:
            inFlightLaunch = Task { [apps] in _ = await apps.launch(at: index) }
        }
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

    func deleteClip(id: UUID) {
        guard mode == .clipboard else { return }
        clips.remove(.item(id))
    }

    func clearHistory() {
        guard mode == .clipboard else { return }
        clips.remove(.all)
    }

    func toggleCapture() {
        clips.toggleCapture()
    }

    // MARK: - Dependencies

    func setSearchService(_ service: SearchService) {
        apps.searchService = service
        service.resetCache()
    }

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

    /// Runs `publish`, then starts selection at the first row and announces the result once.
    private func resetResults(_ publish: () -> Void) {
        isResettingResults = true
        publish()
        isResettingResults = false
        setSelection(resultCount == 0 ? nil : 0)
        onChange?(.results(preservedSelection: false))
    }

    private func wireSubmodels() {
        apps.onPublish = { [weak self] previousCount in self?.resultsPublished(in: .applications, previousCount: previousCount) }
        clips.onPublish = { [weak self] previousCount in self?.resultsPublished(in: .clipboard, previousCount: previousCount) }
        apps.onStatusChange = { [weak self] in self?.onChange?(.status) }
        clips.onStatusChange = { [weak self] in self?.onChange?(.status) }
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
        onChange?(.results(preservedSelection: preserving))
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
