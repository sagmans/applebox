import AppKit
import Darwin

/// Keep local installs separate from release packaging and the user's saved history.
private enum LocalInstall {
    private enum Action: String {
        case install, uninstall
    }

    private enum Failure: LocalizedError {
        case invalidArguments
        case unexpectedBundle(URL)
        case running

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Expected install or uninstall, source bundle, destination bundle, and bundle identifier."
            case let .unexpectedBundle(url): "Refusing to replace or remove an unexpected item at \(url.path)."
            case .running: "Quit Bitekey from its menu before installing, updating, or uninstalling."
            }
        }
    }

    private static let fileManager = FileManager.default
    private static let stagingPrefix = ".bitekey-install-"
    private static let privateDirectoryMode = 0o700
    private static let argumentCount = 5

    static func run(_ arguments: [String]) throws {
        guard arguments.count == argumentCount, let action = Action(rawValue: arguments[1]) else {
            throw Failure.invalidArguments
        }
        let source = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let destination = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let identifier = arguments[4]
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            throw Failure.running
        }

        let installed = try validateInstalledBundle(at: destination, identifier: identifier)
        switch action {
        case .install:
            guard try validateInstalledBundle(at: source, identifier: identifier) else {
                throw Failure.unexpectedBundle(source)
            }
            try install(source, to: destination, replacing: installed)
            print("Installed \(destination.path)")
        case .uninstall:
            if installed {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
                print("Moved \(destination.path) to Trash. Saved history and preferences are kept.")
            }
        }
    }

    private static func validateInstalledBundle(at url: URL, identifier: String) throws -> Bool {
        // Inspect the entry itself so an unrelated directory or symlink is never replaced.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              Bundle(url: url)?.bundleIdentifier == identifier
        else { throw Failure.unexpectedBundle(url) }
        return true
    }

    private static func install(_ source: URL, to destination: URL, replacing: Bool) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: privateDirectoryMode])
        defer {
            do {
                // This is the unique directory created above, including an old bundle after a swap.
                print("Cleaning staging directory \(staging.path)")
                try fileManager.removeItem(at: staging)
            } catch {
                fputs("Could not clean staging directory \(staging.path): \(error)\n", stderr)
            }
        }
        let stagedBundle = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: source, to: stagedBundle)

        // A same-volume swap keeps a usable bundle in place if copying or replacing fails.
        let flags = UInt32(replacing ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, stagedBundle.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

do {
    try LocalInstall.run(CommandLine.arguments)
} catch {
    fputs("Local install failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
