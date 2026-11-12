import Foundation
import OSLog

/// Persists launch recency so search ordering survives restarts; owned outside any view so the
/// models can share one store.
final class RecentApplicationsStore {
    private let fileSystem: FileSystemProtocol
    private let storageURL: URL

    private let queue = DispatchQueue(label: "bitekey.recentApps", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "bitekey.recentApps.persistence", qos: .utility)

    private let fileName = "recent_applications.json"
    private let maxCount = 50
    /// Every Cmd-Tab is an activation, so saving each one rewrote and fsynced the file many times a
    /// minute. One save per window bounds the rate; a crash loses at most this much ordering, which
    /// only affects how the empty query is sorted.
    private static let saveDelay: Duration = .seconds(5)

    private var recentBundlePaths: [String] = []
    /// The delayed save, if one is waiting. Nil means the file already holds the latest order.
    private var pendingSave: Task<Void, Never>?
    /// Records a failed save; the domain and code only, because the file lists which apps the user opens.
    private let logger = Logger(
        subsystem: LogSubsystem.name,
        category: "recentApps"
    )

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem

        let appSupportURL = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileSystem.homeDirectoryForCurrentUser
        let appDirectory = appSupportURL.appendingPathComponent(AppDataLocation.folderName, isDirectory: true)
        if !fileSystem.fileExists(atPath: appDirectory.path) {
            try? fileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        storageURL = appDirectory.appendingPathComponent(fileName)

        recentBundlePaths = loadRecentsFromDisk()
    }

    /// Launch order, most recent first, so the empty-query list can put these apps ahead of the
    /// alphabetical rest. May name apps that are no longer installed; the caller skips those.
    func recentOrder() -> [String] {
        queue.sync { recentBundlePaths }
    }

    /// Moves an app to the front of the recents once it launched, so the order follows real use. Persisting
    /// is delayed and coalesced because a launch must not wait on disk, and app switching would otherwise
    /// rewrite the file on every activation.
    ///
    /// Returns whether the order changed, so callers can skip refreshing views when it did not.
    @discardableResult
    func recordLaunch(bundlePath: String) -> Bool {
        let changed = queue.sync { () -> Bool in
            // Switching back to the app already in front leaves the order as it is.
            guard recentBundlePaths.first != bundlePath else { return false }
            var updated = recentBundlePaths.filter { $0 != bundlePath }
            updated.insert(bundlePath, at: 0)
            if updated.count > maxCount {
                updated = Array(updated.prefix(maxCount))
            }
            recentBundlePaths = updated
            return true
        }

        if changed {
            scheduleSave()
        }
        return changed
    }

    /// Writes a waiting delayed save now and waits for every save to reach disk, so quitting inside the
    /// save window keeps the latest order.
    func flushPendingPersistence() {
        if let pending = pendingSave {
            pending.cancel()
            pendingSave = nil
            persistRecentsAsync(queue.sync { recentBundlePaths })
        }
        persistenceQueue.sync {}
    }

    /// Gives a first run something to show before the user has launched anything. Ignored once recents
    /// exist, so the user's own history is never overwritten by defaults.
    func seedIfEmpty(with bundlePaths: [String]) {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(bundlePaths.count)

        for path in bundlePaths {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }

        guard !ordered.isEmpty else { return }

        let snapshot = queue.sync { () -> [String]? in
            guard recentBundlePaths.isEmpty else { return nil }
            let limited = Array(ordered.prefix(maxCount))
            recentBundlePaths = limited
            return limited
        }

        guard let snapshot else { return }
        // A seed is one write at startup, so it saves at once and never waits on the save window.
        persistRecentsAsync(snapshot)
    }

    /// Starts one delayed save unless one is already waiting. The save reads the order when it fires, so
    /// every activation inside the window lands in that single write.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.saveDelay)
            } catch {
                // Cancelled because a flush already wrote this order.
                return
            }
            // A flush can cancel after the sleep ended but before this resumed; it already wrote, and
            // clearing pendingSave here could drop a newer save it scheduled.
            guard !Task.isCancelled, let self else { return }
            pendingSave = nil
            persistRecentsAsync(queue.sync { recentBundlePaths })
        }
    }

    /// Saves owner-only, like the clipboard history: launch history shows what the user works with, and
    /// the umask default would leave it readable by other users once the directory is moved or loosened.
    /// A failed save is logged and otherwise ignored, because recents only order results and the next
    /// launch saves again.
    private func persistRecentsAsync(_ snapshot: [String]) {
        persistenceQueue.async { [snapshot, storageURL, fileSystem, logger] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try fileSystem.writePrivateFile(data, to: storageURL)
            } catch {
                let failure = error as NSError
                logger.error("Recent applications save failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            }
        }
    }

    private func loadRecentsFromDisk() -> [String] {
        guard fileSystem.fileExists(atPath: storageURL.path), let data = fileSystem.contents(atPath: storageURL.path) else { return [] }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode([String].self, from: data)
        } catch {
            return []
        }
    }
}
