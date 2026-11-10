import AppKit
import Observation
import OSLog

/// Builds application rows away from the main actor so the list only ever receives finished value
/// snapshots and never touches the indexer or matcher while rendering.
nonisolated enum AppRowBuilder {
    /// Same-named apps need their folder shown to be told apart, so the set is classified over the whole
    /// result list before any row is made.
    static func rows(from results: [SearchResult], recentPaths: Set<String> = []) -> [AppRowData] {
        var seenNames: Set<String> = []
        var duplicateNames: Set<String> = []
        for result in results where !seenNames.insert(result.application.name).inserted {
            duplicateNames.insert(result.application.name)
        }

        return results.map { result in
            let application = result.application
            return AppRowData(
                id: application.bundlePath,
                name: application.name,
                location: duplicateNames.contains(application.name)
                    ? (application.bundlePath as NSString).abbreviatingWithTildeInPath
                    : nil,
                runs: matchRuns(in: application.name, indices: result.matchedIndices),
                isRecent: recentPaths.contains(application.bundlePath)
            )
        }
    }
}

/// The empty-query rows without recents, built once per index revision.
///
/// Every panel show and every app activation while the panel is open re-shows the recents. Sorting all
/// installed apps by Unicode name and building their rows each time cost about 1 ms on the main actor,
/// although only the short recents prefix changes between shows.
nonisolated struct AlphabeticalAppRows {
    /// The index revision these rows were built from; a different one means apps were added, removed
    /// or renamed.
    let revision: UInt64
    /// One row per bundle path, alphabetical, none flagged recent.
    private let rows: [AppRowData]
    /// Lets the recents be found without a scan of `rows`.
    private let positionByPath: [String: Int]

    init(applications: [ApplicationInfo], revision: UInt64) {
        self.revision = revision
        // A restored cache can repeat a path. Keep the first record so recents still open.
        let unique = Dictionary(applications.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        // Bundle paths are unique here, so this order is total and the same on every rebuild.
        let sorted = unique.values.sorted { $0.isOrderedBefore($1) }
        rows = AppRowBuilder.rows(from: sorted.map { SearchResult(application: $0, score: 0, matchedIndices: []) })
        positionByPath = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
    }

    /// Puts recently launched apps first in launch order and the rest alphabetically, so the empty query
    /// shows what the user is most likely to want. Linear in the app count; nothing is sorted.
    func ordered(recentPaths: [String]) -> [AppRowData] {
        var placed = Set<String>(minimumCapacity: recentPaths.count)
        var ordered: [AppRowData] = []
        ordered.reserveCapacity(rows.count)

        for path in recentPaths {
            // A stored path can be repeated or name an app that is gone; neither may add a row.
            guard let position = positionByPath[path], placed.insert(path).inserted else { continue }
            let row = rows[position]
            ordered.append(AppRowData(id: row.id, name: row.name, location: row.location, runs: row.runs, isRecent: true))
        }

        for row in rows where !placed.contains(row.id) {
            ordered.append(row)
        }
        return ordered
    }
}

/// How a launch request ended, kept as plain values so it can cross from the workspace callback.
private nonisolated enum LaunchOutcome: Sendable {
    case opened
    case failed(domain: String?, code: Int?)
    case timedOut
}

/// A launch can finish through the workspace callback or the timeout; whichever comes first must
/// resolve the waiting caller exactly once, or a late callback would resume a spent continuation.
private final class LaunchRace {
    private var continuation: CheckedContinuation<LaunchOutcome, Never>?

    init(_ continuation: CheckedContinuation<LaunchOutcome, Never>) {
        self.continuation = continuation
    }

    func resolve(_ outcome: LaunchOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// Application results, the recents ordering for an empty query, and launching.
///
/// Rows are published as value snapshots. Each search carries a sequence number so a slow result for
/// an older query can never overwrite the rows of a newer one.
@Observable
final class AppSearchModel {
    /// Rows for the current query, ready to render without touching services.
    private(set) var rows: [AppRowData] = []
    /// Bumped whenever `rows` is replaced. Views key row animations on it because comparing it is O(1),
    /// while comparing row identities would cost a pass over the list on every redraw.
    private(set) var rowsGeneration = 0

    /// Latest launch failure, or nil while nothing is wrong; cleared when the user moves on.
    private(set) var launchStatus: LauncherStatus?
    /// Counts failed launches. Two failures with the same message are equal statuses, so views that react
    /// to each failure (the search bar shake) watch this instead of the status.
    private(set) var launchFailureCount = 0

    /// Set by the shell once indexing exists, because the UI must be usable before the index is.
    @ObservationIgnored var searchService: SearchService? {
        // Revisions count per indexer, so a new service's revision can match rows built from the old one.
        didSet { alphabeticalRows = nil }
    }

    /// Reused by `showRecents` until the index revision changes.
    @ObservationIgnored private var alphabeticalRows: AlphabeticalAppRows?

    /// Told the previous row count after rows are replaced, so the owner can fix its selection.
    @ObservationIgnored var onPublish: ((_ previousCount: Int) -> Void)?

    /// Told when a launch the user still cares about succeeded, so the owner can dismiss the launcher.
    @ObservationIgnored var onLaunched: (() -> Void)?

    /// Told when the recents ordering moved, so an empty-query list can refresh in place.
    @ObservationIgnored var onRecentsChanged: (() -> Void)?

    @ObservationIgnored private let workspace: WorkspaceProtocol
    @ObservationIgnored private let fileSystem: FileSystemProtocol
    @ObservationIgnored private let recents: RecentApplicationsStore
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var pendingLaunch: UUID?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let logger = Logger(
        subsystem: LogSubsystem.name,
        category: "launcher"
    )

    init(workspace: WorkspaceProtocol, fileSystem: FileSystemProtocol, recents: RecentApplicationsStore) {
        self.workspace = workspace
        self.fileSystem = fileSystem
        self.recents = recents
        observeWorkspaceActivity()
    }

    /// Isolated so teardown can read the main-actor observer list.
    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }

    // MARK: - Searching

    /// Searches off the main actor and publishes only if no newer search began meanwhile.
    ///
    /// An empty query shows the recents ordering instead, because the user has asked for nothing specific.
    func search(_ query: String) async {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            invalidatePendingSearch()
            searchService?.resetCache()
            showRecents()
            return
        }

        sequence &+= 1
        let ticket = sequence
        let built = await Self.buildOffMain(service: searchService, query: query)
        // A cancelled task returns early with partial output, which must never reach the list.
        guard ticket == sequence, !Task.isCancelled else { return }
        publish(built)
    }

    /// Runs the same search on the caller's actor, for callers that cannot await and need the rows at once.
    func searchImmediately(_ query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            invalidatePendingSearch()
            searchService?.resetCache()
            showRecents()
            return
        }

        invalidatePendingSearch()
        publish(Self.build(service: searchService, query: query))
    }

    /// Shows installed apps with recently launched ones first, which is what an empty query means.
    func showRecents() {
        guard let searchService else { return }

        let snapshot = searchService.applicationSnapshot()
        let base: AlphabeticalAppRows
        if let cached = alphabeticalRows, cached.revision == snapshot.revision {
            base = cached
        } else {
            base = AlphabeticalAppRows(applications: snapshot.applications, revision: snapshot.revision)
            alphabeticalRows = base
        }
        invalidatePendingSearch()
        publish(base.ordered(recentPaths: recents.recentOrder()))
    }

    /// Replaces the rows with results computed elsewhere, such as snapshot fixtures.
    func setResults(_ results: [SearchResult]) {
        invalidatePendingSearch()
        publish(AppRowBuilder.rows(from: results))
    }

    /// Empties the list without announcing it, for callers that are about to publish the next set.
    func clear() {
        invalidatePendingSearch()
        rows = []
        rowsGeneration &+= 1
    }

    /// Makes any search still in flight stale, so a late result cannot land after the list was reset.
    func invalidatePendingSearch() {
        sequence &+= 1
    }

    /// The search cache only speeds up refinements; dropping it keeps a new typing session independent.
    func resetSearchCache() {
        searchService?.resetCache()
    }

    private func publish(_ newRows: [AppRowData]) {
        let previousCount = rows.count
        rows = newRows
        rowsGeneration &+= 1
        onPublish?(previousCount)
    }

    private nonisolated static func build(service: SearchService?, query: String) -> [AppRowData] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = service?.search(trimmed) { Task.isCancelled } ?? []
        return AppRowBuilder.rows(from: results)
    }

    /// Matching is the only per-keystroke cost that grows with the index, so it runs on the global executor.
    @concurrent
    private static func buildOffMain(service: SearchService?, query: String) async -> [AppRowData] {
        build(service: service, query: query)
    }

    // MARK: - Launching

    /// Opens the app at `bundlePath`. Returns the failure to show, or nil when the launch succeeded, was
    /// superseded, or had nothing to act on.
    ///
    /// The caller names the app by path, not by row position, because rows can be replaced between the
    /// key press and this call; a path no longer listed is ignored rather than launching a neighbour.
    ///
    /// Success dismisses the launcher through `onLaunched` only while the request is still the one the
    /// user is waiting for, so a launch they abandoned cannot close a window they moved on to.
    func launch(bundlePath: String) async -> LauncherStatus? {
        guard rows.contains(where: { $0.id == bundlePath }), pendingLaunch == nil else { return nil }
        clearLaunchStatus()

        guard fileSystem.fileExists(atPath: bundlePath) else {
            logger.notice("Selected application bundle no longer exists")
            return fail(DesignTokens.Copy.appMissing)
        }

        let request = UUID()
        pendingLaunch = request
        let outcome = await open(bundlePath: bundlePath)

        guard pendingLaunch == request else { return nil }
        switch outcome {
        case .opened:
            pendingLaunch = nil
            onLaunched?()
            return nil
        case let .failed(domain, code):
            if let domain, let code {
                logger.error("Application launch failed: \(domain, privacy: .public) \(code, privacy: .public)")
            } else {
                logger.error("Application launch returned without a running application")
            }
            return fail(DesignTokens.Copy.launchFailed)
        case .timedOut:
            logger.error("Application launch timed out")
            return fail(DesignTokens.Copy.launchTimedOut)
        }
    }

    /// Waits for the workspace or the timeout, whichever is first.
    ///
    /// A confirmed launch is recorded in the callback itself, so it still counts toward recents after the
    /// timeout already told the user it was slow.
    private func open(bundlePath: String) async -> LaunchOutcome {
        let timeout = DesignTokens.Timing.launchTimeout
        var timer: Task<Void, Never>?
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<LaunchOutcome, Never>) in
            let race = LaunchRace(continuation)
            timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because the launch finished first; nothing is left to time out.
                    return
                }
                race.resolve(.timedOut)
            }

            let config = NSWorkspace.OpenConfiguration()
            // A running copy at another path must not replace the row the user chose.
            config.allowsRunningApplicationSubstitution = false
            config.promptsUserIfNeeded = false
            workspace.openApplication(at: URL(fileURLWithPath: bundlePath), configuration: config) { [weak self] app, error in
                let failure = error as NSError?
                let outcome: LaunchOutcome = app != nil && error == nil
                    ? .opened
                    : .failed(domain: failure?.domain, code: failure?.code)
                // The workspace calls back on an arbitrary queue; state changes belong on the main actor.
                Task { @MainActor in
                    if case .opened = outcome {
                        self?.recents.recordLaunch(bundlePath: bundlePath)
                    }
                    race.resolve(outcome)
                }
            }
        }
        timer?.cancel()
        return outcome
    }

    private func fail(_ message: String) -> LauncherStatus {
        pendingLaunch = nil
        let status = LauncherStatus.error(message)
        launchStatus = status
        launchFailureCount &+= 1
        return status
    }

    /// Drops a pending launch and its message, so feedback never outlives the query it was about.
    func clearLaunchStatus() {
        pendingLaunch = nil
        guard launchStatus != nil else { return }
        launchStatus = nil
    }

    // MARK: - Recents

    /// Saves recents still waiting in the store's save window, so a quit keeps the latest order.
    func flushPendingRecents() {
        recents.flushPendingPersistence()
    }

    /// Keeps launch recency current for apps started outside AppleBox too, so the empty-query order
    /// reflects what the user actually used.
    private func observeWorkspaceActivity() {
        guard workspace is SystemWorkspace else { return }

        let center = NSWorkspace.shared.notificationCenter
        let runningBundles = NSWorkspace.shared.runningApplications
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { app -> String? in
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
                return app.bundleURL?.path
            }
        recents.seedIfEmpty(with: runningBundles)

        // Observers are registered on the main queue, which the compiler cannot see through the Sendable block.
        let handler: @Sendable (Notification) -> Void = { [weak self] notification in
            // Extract plain values here because NSRunningApplication cannot cross into the isolated block.
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundlePath = app?.bundleURL?.path
            let isSelf = app?.bundleIdentifier == Bundle.main.bundleIdentifier
            guard let self, let bundlePath, !isSelf else { return }
            MainActor.assumeIsolated {
                // Most activations return to the app already in front; nothing to redraw then.
                if recents.recordLaunch(bundlePath: bundlePath) {
                    onRecentsChanged?()
                }
            }
        }

        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: handler),
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: handler),
        ]
    }
}
