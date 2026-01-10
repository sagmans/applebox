import AppKit

struct ApplicationInfo {
    let name: String
    let bundlePath: String
}

class ApplicationIndexer {
    private var applications: [ApplicationInfo] = []
    private let fileSystem: FileSystemProtocol

    // Paths to scan for applications
    private var searchPaths: [URL] {
        var paths: [URL] = []

        // System Applications
        let systemApps = URL(fileURLWithPath: "/System/Applications")
        paths.append(systemApps)

        // Main Applications folder
        let mainApps = URL(fileURLWithPath: "/Applications")
        paths.append(mainApps)

        // User Applications folder
        let userApps = fileSystem.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        paths.append(userApps)

        return paths
    }

    var allApplications: [ApplicationInfo] {
        return applications
    }

    init(fileSystem: FileSystemProtocol = SystemFileManager()) {
        self.fileSystem = fileSystem
        // Initial scan
        scanForApplications()
    }

    func scanForApplications() {
        applications.removeAll()

        for path in searchPaths {
            scanDirectory(at: path)
        }

        print("Found \(applications.count) applications")
    }

    private func scanDirectory(at url: URL) {
        // Skip if directory doesn't exist
        guard fileSystem.fileExists(atPath: url.path) else {
            return
        }

        do {
            let contents = try fileSystem.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [URLResourceKey.isRegularFileKey, URLResourceKey.isDirectoryKey],
                options: [FileManager.DirectoryEnumerationOptions.skipsHiddenFiles]
            )

            for item in contents {
                var isDirectory: ObjCBool = false

                // Check if item is a directory
                if fileSystem.fileExists(atPath: item.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {

                    // Check if it's an app bundle (has .app extension)
                    if item.pathExtension == "app" {
                        // Extract app name from bundle
                        let appName = item.deletingPathExtension().lastPathComponent
                        let appInfo = ApplicationInfo(name: appName, bundlePath: item.path)

                        // Avoid duplicates
                        if !applications.contains(where: { $0.bundlePath == item.path }) {
                            applications.append(appInfo)
                            print("Found: \(appName)")
                        }
                    }
                }
            }
        } catch {
            print("Error scanning directory \(url.path): \(error.localizedDescription)")
        }
    }

    func searchApplications(query: String) -> [ApplicationInfo] {
        guard !query.isEmpty else {
            return applications.sorted { $0.name < $1.name }
        }

        let lowerQuery = query.lowercased()
        return applications.filter { app in
            app.name.lowercased().contains(lowerQuery)
        }.sorted { $0.name < $1.name }
    }
}
