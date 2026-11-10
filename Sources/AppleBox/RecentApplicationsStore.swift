import Foundation

/// Persists launch recency so search ordering survives restarts; owned outside any view so the
/// models can share one store.
final class RecentApplicationsStore {
    private let fileSystem: FileSystemProtocol
    private let storageURL: URL

    private let queue = DispatchQueue(label: "applebox.recentApps", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "applebox.recentApps.persistence", qos: .utility)

    private let fileName = "recent_applications.json"
    private let maxCount = 50

    private var recentBundlePaths: [String] = []

    init(fileSystem: FileSystemProtocol) {
        self.fileSystem = fileSystem

        let appSupportURL = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileSystem.homeDirectoryForCurrentUser
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        if !fileSystem.fileExists(atPath: appDirectory.path) {
            try? fileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        storageURL = appDirectory.appendingPathComponent(fileName)

        recentBundlePaths = loadRecentsFromDisk()
    }

    /// Puts recently launched apps first in launch order and the rest alphabetically, so the empty query
    /// shows what the user is most likely to want.
    func orderedApplications(from applications: [ApplicationInfo]) -> [ApplicationInfo] {
        let snapshot = queue.sync { recentBundlePaths }
        // A restored cache can repeat a path. Keep the first record so recents still open.
        var remaining = Dictionary(applications.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [ApplicationInfo] = []
        ordered.reserveCapacity(applications.count)

        for bundlePath in snapshot {
            if let app = remaining.removeValue(forKey: bundlePath) {
                ordered.append(app)
            }
        }

        let tail = remaining.values.sorted { $0.isOrderedBefore($1) }
        ordered.append(contentsOf: tail)
        return ordered
    }

    /// Lets row builders flag recents without re-deriving them from the sorted order, which would
    /// make an alphabetical tail indistinguishable from launch history.
    func recentSnapshot() -> Set<String> {
        queue.sync { Set(recentBundlePaths) }
    }

    /// Moves an app to the front of the recents once it launched, so the order follows real use. Persisting
    /// is asynchronous because a launch must not wait on disk.
    func recordLaunch(bundlePath: String) {
        let snapshot = queue.sync { () -> [String] in
            var updated = recentBundlePaths.filter { $0 != bundlePath }
            updated.insert(bundlePath, at: 0)
            if updated.count > maxCount {
                updated = Array(updated.prefix(maxCount))
            }
            recentBundlePaths = updated
            return updated
        }

        persistRecentsAsync(snapshot)
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
        persistRecentsAsync(snapshot)
    }

    private func persistRecentsAsync(_ snapshot: [String]) {
        persistenceQueue.async { [snapshot, storageURL, fileSystem] in
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(snapshot)
                _ = fileSystem.createFile(atPath: storageURL.path, contents: data, attributes: nil)
            } catch {
                // Best-effort persistence.
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
