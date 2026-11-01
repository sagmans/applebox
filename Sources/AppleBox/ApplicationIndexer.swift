import AppKit

struct ApplicationInfo {
    let name: String
    let bundlePath: String
    /// Cached normalized name for fast matching.
    let normalizedName: String
    /// Pre-computed lowercased UTF-8 bytes for O(1) fuzzy matching.
    let normalizedNameBytes: ContiguousArray<UInt8>

    init(name: String, bundlePath: String) {
        self.name = name
        self.bundlePath = bundlePath
        let normalized = name.lowercased()
        normalizedName = normalized
        normalizedNameBytes = ContiguousArray(normalized.utf8)
    }
}

private struct CachedApplication: Codable {
    let name: String
    let bundlePath: String
}

final class ApplicationIndexer {
    private let fileSystem: FileSystemProtocol
    private let storageURL: URL

    private let applicationsQueue = DispatchQueue(label: "applebox.applicationIndexer.apps", attributes: .concurrent)
    private var applications: [ApplicationInfo] = []

    private let scanQueue = DispatchQueue(label: "applebox.applicationIndexer.scan", qos: .utility)
    private let persistenceQueue = DispatchQueue(label: "applebox.applicationIndexer.persistence", qos: .utility)

    private let cacheFileName = "applications_cache.json"

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
        applicationsQueue.sync { applications }
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
            guard let self else { return }
            let scanned = scanForApplicationsInternal()
            applicationsQueue.async(flags: .barrier) {
                self.applications = scanned
                self.persistApplicationsAsync(scanned)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("applebox.applicationIndex.didUpdate"), object: nil)
                    completion?(scanned)
                }
            }
        }
    }

    func scanForApplications() {
        let scanned = scanForApplicationsInternal()
        applicationsQueue.sync(flags: .barrier) {
            self.applications = scanned
        }
        persistApplicationsAsync(scanned)
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
            let cached = try decoder.decode([CachedApplication].self, from: data)
            return cached.map { ApplicationInfo(name: $0.name, bundlePath: $0.bundlePath) }
        } catch {
            return []
        }
    }

    private func persistApplicationsAsync(_ applications: [ApplicationInfo]) {
        let snapshot = applications.map { CachedApplication(name: $0.name, bundlePath: $0.bundlePath) }
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

    private func scanForApplicationsInternal() -> [ApplicationInfo] {
        var found: [ApplicationInfo] = []
        found.reserveCapacity(1024)

        for path in searchPaths {
            found.append(contentsOf: scanDirectory(at: path))
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

    private func scanDirectory(at url: URL) -> [ApplicationInfo] {
        // Skip if directory doesn't exist
        guard fileSystem.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let contents = try fileSystem.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [URLResourceKey.isRegularFileKey, URLResourceKey.isDirectoryKey],
                options: [FileManager.DirectoryEnumerationOptions.skipsHiddenFiles]
            )

            var results: [ApplicationInfo] = []
            results.reserveCapacity(contents.count)

            for item in contents {
                var isDirectory: ObjCBool = false

                if fileSystem.fileExists(atPath: item.path, isDirectory: &isDirectory),
                   isDirectory.boolValue,
                   item.pathExtension == "app"
                {
                    let appName = item.deletingPathExtension().lastPathComponent
                    results.append(ApplicationInfo(name: appName, bundlePath: item.path))
                }
            }

            return results
        } catch {
            return []
        }
    }

    func searchApplications(query: String) -> [ApplicationInfo] {
        // Legacy, not used by launcher search. Keep behavior consistent.
        let apps = allApplications
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return apps.sorted { $0.name < $1.name }
        }

        let lowerQuery = trimmed.lowercased()
        return apps.filter { app in
            app.normalizedName.contains(lowerQuery)
        }.sorted { $0.name < $1.name }
    }
}
