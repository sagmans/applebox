import AppKit
import OSLog

struct ApplicationInfo {
    let name: String
    let bundlePath: String
    /// Cached normalized name for fast matching.
    let normalizedName: String
    /// Pre-computed lowercased UTF-8 bytes for O(1) fuzzy matching.
    let normalizedNameBytes: ContiguousArray<UInt8>
    /// People may know the installed filename even when Finder displays a localized name.
    let normalizedFilename: String?
    let normalizedFilenameBytes: ContiguousArray<UInt8>?

    init(name: String, bundlePath: String) {
        self.name = name
        self.bundlePath = bundlePath
        let normalized = name.lowercased()
        normalizedName = normalized
        normalizedNameBytes = ContiguousArray(normalized.utf8)
        let filename = URL(fileURLWithPath: bundlePath, isDirectory: true).deletingPathExtension().lastPathComponent.lowercased()
        normalizedFilename = filename == normalized ? nil : filename
        normalizedFilenameBytes = normalizedFilename.map { ContiguousArray($0.utf8) }
    }

    /// Keep copies with identical display names in a stable order across scans.
    func isOrderedBefore(_ other: Self) -> Bool {
        name == other.name ? bundlePath < other.bundlePath : name < other.name
    }
}

private struct CachedApplication: Codable {
    let name: String
    let bundlePath: String
}

private struct ApplicationIndexCache: Codable {
    let version: Int
    let entries: [CachedApplication]
}

final class ApplicationIndexer {
    static let didUpdate = Notification.Name("applebox.applicationIndex.didUpdate")

    private let fileSystem: FileSystemProtocol
    private let storageURL: URL

    private let applicationsQueue = DispatchQueue(label: "applebox.applicationIndexer.apps", attributes: .concurrent)
    private var applications: [ApplicationInfo] = []
    private var revision: UInt64 = 0

    private let scanQueue = DispatchQueue(label: "applebox.applicationIndexer.scan", qos: .utility)
    private let persistenceQueue = DispatchQueue(label: "applebox.applicationIndexer.persistence", qos: .utility)
    private var folderMonitor: ApplicationFolderMonitor?
    private var folderRefreshPending = false
    private let refreshDelay: DispatchTimeInterval = .milliseconds(250)

    private let cacheFileName = "applications_cache.json"
    private let cacheVersion = 2
    private let applicationExtension = "app"
    private let maximumDirectoryDepth = 5
    private let maximumEntriesPerRoot = 4096
    private let scanResourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox", category: "index")

    /// Paths to scan for applications
    private var searchPaths: [URL] {
        var paths: [URL] = []

        // System Applications
        paths.append(URL(fileURLWithPath: "/System/Applications"))

        // System Utilities (Activity Monitor, Disk Utility, Terminal, etc.)
        paths.append(URL(fileURLWithPath: "/System/Applications/Utilities"))

        // Main Applications folder
        paths.append(URL(fileURLWithPath: "/Applications"))

        // Applications/Utilities (user-installed utilities)
        paths.append(URL(fileURLWithPath: "/Applications/Utilities"))

        // User Applications folder
        let userApps = fileSystem.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        paths.append(userApps)

        return paths
    }

    var allApplications: [ApplicationInfo] {
        snapshot.applications
    }

    /// Pair candidates with their revision so an equal-count replacement invalidates searches.
    var snapshot: (applications: [ApplicationInfo], revision: UInt64) {
        applicationsQueue.sync { (applications, revision) }
    }

    init(fileSystem: FileSystemProtocol = SystemFileManager(), scanSynchronously: Bool = true) {
        self.fileSystem = fileSystem

        let appSupportURL = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileSystem.homeDirectoryForCurrentUser
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)
        if !fileSystem.fileExists(atPath: appDirectory.path) {
            try? fileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        storageURL = appDirectory.appendingPathComponent(cacheFileName)

        loadCachedApplications()

        if scanSynchronously {
            scanForApplications()
        }
    }

    func scanForApplicationsAsync(completion: (([ApplicationInfo]) -> Void)? = nil) {
        scanQueue.async { [weak self] in
            self?.publishScan(completion: completion)
        }
    }

    func startMonitoring() {
        guard folderMonitor == nil else { return }
        let paths = searchPaths.map(\.path)
        folderMonitor = ApplicationFolderMonitor(paths: paths) { [weak self] in
            self?.scheduleFolderRefresh()
        }
        if folderMonitor == nil {
            logger.error("Cannot start application folder monitoring for \(paths.count, privacy: .public) roots")
        }
    }

    func refreshIfMonitoringUnavailable() {
        if folderMonitor == nil {
            scanForApplicationsAsync()
        }
    }

    private func scheduleFolderRefresh() {
        scanQueue.async { [weak self] in
            guard let self, !folderRefreshPending else { return }
            folderRefreshPending = true
            // A copy or move can emit several batches while bundle contents settle.
            scanQueue.asyncAfter(deadline: .now() + refreshDelay) { [weak self] in
                guard let self else { return }
                folderRefreshPending = false
                publishScan(completion: nil)
            }
        }
    }

    private func publishScan(completion: (([ApplicationInfo]) -> Void)?) {
        let scanned = scanForApplicationsInternal()
        applicationsQueue.async(flags: .barrier) {
            let changed = !self.applications.elementsEqual(scanned) {
                $0.bundlePath == $1.bundlePath && $0.name == $1.name
            }
            if changed {
                self.applications = scanned
                self.revision &+= 1
                self.persistApplicationsAsync(scanned)
            }
            DispatchQueue.main.async {
                if changed {
                    NotificationCenter.default.post(name: Self.didUpdate, object: self)
                }
                completion?(scanned)
            }
        }
    }

    func scanForApplications() {
        scanQueue.sync {
            let scanned = scanForApplicationsInternal()
            applicationsQueue.sync(flags: .barrier) {
                self.applications = scanned
                revision &+= 1
            }
            persistApplicationsAsync(scanned)
        }
    }

    private func loadCachedApplications() {
        let cached = loadCachedApplicationsFromDisk()
        guard !cached.isEmpty else { return }
        applicationsQueue.sync(flags: .barrier) {
            self.applications = cached
        }
    }

    private func loadCachedApplicationsFromDisk() -> [ApplicationInfo] {
        guard fileSystem.fileExists(atPath: storageURL.path), let data = fileSystem.contents(atPath: storageURL.path) else { return [] }

        do {
            let decoder = JSONDecoder()
            let cached = try decoder.decode(ApplicationIndexCache.self, from: data)
            // Older scans accepted directories that happened to end in .app.
            guard cached.version == cacheVersion else { return [] }
            return cached.entries.map { ApplicationInfo(name: $0.name, bundlePath: $0.bundlePath) }
        } catch {
            return []
        }
    }

    private func persistApplicationsAsync(_ applications: [ApplicationInfo]) {
        let entries = applications.map { CachedApplication(name: $0.name, bundlePath: $0.bundlePath) }
        let snapshot = ApplicationIndexCache(version: cacheVersion, entries: entries)
        persistenceQueue.async { [snapshot, storageURL, fileSystem] in
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(snapshot)
                try fileSystem.write(data, to: storageURL, options: [.atomic])
            } catch {
                // Best-effort persistence.
            }
        }
    }

    private func scanForApplicationsInternal() -> [ApplicationInfo] {
        var found: [ApplicationInfo] = []
        found.reserveCapacity(1024)

        for path in searchPaths {
            var remainingEntries = maximumEntriesPerRoot
            scanDirectory(at: path, depth: 0, remainingEntries: &remainingEntries, into: &found)
        }

        // De-dupe by bundle path
        var seen = Set<String>()
        seen.reserveCapacity(found.count)
        var deduped: [ApplicationInfo] = []
        deduped.reserveCapacity(found.count)
        for app in found {
            if seen.insert(app.bundlePath).inserted {
                deduped.append(app)
            }
        }

        return deduped
    }

    private func scanDirectory(at url: URL, depth: Int, remainingEntries: inout Int, into results: inout [ApplicationInfo]) {
        guard remainingEntries > 0, fileSystem.fileExists(atPath: url.path) else { return }

        do {
            let contents = try fileSystem.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: scanResourceKeys,
                options: [.skipsHiddenFiles],
                limit: remainingEntries
            )
            // Account for the shallow listing before descending so each root gets an independent budget.
            remainingEntries -= contents.count

            for item in contents {
                if item.pathExtension.caseInsensitiveCompare(applicationExtension) == .orderedSame {
                    // Never index embedded helpers, including inside malformed bundles.
                    if fileSystem.isApplicationBundle(at: item) {
                        results.append(ApplicationInfo(name: displayName(for: item), bundlePath: item.path))
                    }
                } else if depth < maximumDirectoryDepth, fileSystem.isApplicationSearchFolder(at: item) {
                    scanDirectory(at: item, depth: depth + 1, remainingEntries: &remainingEntries, into: &results)
                }
            }
        } catch {
            let failure = error as NSError
            logger.error("Cannot enumerate application folder at depth \(depth, privacy: .public): \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        }
    }

    private func displayName(for app: URL) -> String {
        // Use the same filesystem name as Finder while keeping the launcher free of bundle extensions.
        let displayName = fileSystem.displayName(atPath: app.path).trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let name = displayName.pathExtension.caseInsensitiveCompare(applicationExtension) == .orderedSame ? displayName.deletingPathExtension : displayName as String
        return name.isEmpty ? app.deletingPathExtension().lastPathComponent : name
    }

    func searchApplications(query: String) -> [ApplicationInfo] {
        // Legacy, not used by launcher search. Keep behavior consistent.
        let apps = allApplications
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return apps.sorted { $0.isOrderedBefore($1) }
        }

        let lowerQuery = trimmed.lowercased()
        return apps.filter { app in
            app.normalizedName.contains(lowerQuery) || app.normalizedFilename?.contains(lowerQuery) == true
        }.sorted { $0.isOrderedBefore($1) }
    }
}
