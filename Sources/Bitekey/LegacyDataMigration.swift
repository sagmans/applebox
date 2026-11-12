import Foundation

/// Carries a user's data over from the app's former name, so the rename does not look like data loss.
///
/// Runs once, first thing in `AppDelegate.startServices()`, before any store loads its files or
/// reads its preferences. The legacy folder and legacy defaults domain are only ever read: the
/// previous install stays intact, so a user can roll back to it and a failed migration loses nothing.
nonisolated struct LegacyDataMigration {
    /// Outcome of one migration step.
    enum StepResult: Equatable {
        case done
        case skipped
        case failed(Failure)
    }

    /// A failure with its error domain and code kept apart from the free text, so the boundary log
    /// can show the stable fields publicly and keep the text, which may hold paths, private.
    struct Failure: Equatable, ExpressibleByStringLiteral {
        let detail: String
        let domain: String
        let code: Int

        init(stringLiteral value: String) {
            detail = value
            domain = LegacyDataMigration.logicDomain
            code = 0
        }

        init(_ error: Error) {
            let bridged = error as NSError
            detail = String(describing: error)
            domain = bridged.domain
            code = bridged.code
        }

        fileprivate init(detail: String, domain: String, code: Int) {
            self.detail = detail
            self.domain = domain
            self.code = code
        }
    }

    /// Steps are reported separately because they fail independently: a folder failure must still
    /// let the preferences move over, and a stale-temp failure must not block either.
    struct Report: Equatable {
        let staleTemps: StepResult
        let folder: StepResult
        let preferences: StepResult
    }

    /// Raised for outcomes that are not a thrown system error, so they still carry a cause chain.
    private enum MigrationError: Error {
        case copyIsNotDirectory
    }

    static let legacyBundleID = "com.assagman.applebox"
    static let legacyFolderName = "AppleBox"
    /// Allowlist, not denylist: the legacy domain also reports global-domain keys and keys of
    /// unrelated features, which must not leak into the new domain.
    static let allowedKeyPrefixes = ["GlobalShortcut."]
    static let allowedKeys = ["ClipboardCapturePaused"]
    /// Set only after a completed pass, so a user's later changes in the new domain are never
    /// overwritten by a second run.
    static let markerKey = "LegacyDataMigration.preferencesDone"
    /// Marks half-copied folders; a crash mid-copy leaves one behind, and the next run removes it.
    static let tempPrefix = ".bitekey-migration-"
    /// Marks a finished or intentionally skipped folder step. A failed folder step leaves it unset,
    /// because the stores create the new folder right after, and without it the next launch would
    /// see "new folder exists" and silently never retry or report.
    static let folderMarkerKey = "LegacyDataMigration.folderDone"
    /// Error domain for failures that do not come from a system error.
    static let logicDomain = "LegacyDataMigration"
    private static let newFolderExistsDetail = "new data folder exists; legacy data not copied"
    private static let legacyNotDirectoryDetail = "legacy data folder is not a plain directory; not copied"
    private static let cleanupFailedSeparator = "; temp cleanup failed: "
    private static let detailSeparator = "; "
    /// Bounds the sibling listing used to find stale temp folders.
    private static let siblingListingLimit = 1000

    private let fileSystem: FileSystemProtocol
    private let preferences: UserDefaults
    private let legacyPreferences: UserDefaults?

    init(
        fileSystem: FileSystemProtocol = SystemFileManager(),
        preferences: UserDefaults = .standard,
        legacyPreferences: UserDefaults? = UserDefaults(suiteName: LegacyDataMigration.legacyBundleID)
    ) {
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.legacyPreferences = legacyPreferences
    }

    /// Never throws: a failed migration must not stop the launch. The caller logs the report once.
    func run() -> Report {
        // The sweep runs first and on every run: a crash leaves temp folders behind even when no
        // folder step is due, and they hold a full copy of the user's data.
        let staleTemps = sweepStaleTemps()
        return Report(staleTemps: staleTemps, folder: migrateFolder(), preferences: migratePreferences())
    }

    // MARK: - Folder

    private var appSupportURL: URL {
        fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileSystem.homeDirectoryForCurrentUser
    }

    private func migrateFolder() -> StepResult {
        guard !preferences.bool(forKey: Self.folderMarkerKey) else { return .skipped }

        let appSupport = appSupportURL
        let newFolder = appSupport.appendingPathComponent(AppDataLocation.folderName, isDirectory: true)
        let legacyFolder = appSupport.appendingPathComponent(Self.legacyFolderName, isDirectory: true)

        let legacyKind: FileItemKind
        do {
            legacyKind = try fileSystem.itemKind(at: legacyFolder)
        } catch {
            // A read error is retried next launch, never remembered as "nothing to migrate".
            return .failed(Failure(error))
        }
        // A legacy symlink could point anywhere and is never followed, but it shows as a failure
        // rather than being skipped silently.
        switch legacyKind {
        case .missing:
            preferences.set(true, forKey: Self.folderMarkerKey)
            return .skipped
        case .symbolicLink, .other:
            return .failed(Failure(stringLiteral: Self.legacyNotDirectoryDetail))
        case .directory:
            break
        }
        // Merging into existing new data could overwrite it, so report it on every launch instead.
        guard !fileSystem.fileExists(atPath: newFolder.path) else {
            return .failed(Failure(stringLiteral: Self.newFolderExistsDetail))
        }

        // A temp folder is a sibling of the target so the final move stays on one volume and is atomic.
        let temp = appSupport.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try fileSystem.copyItem(at: legacyFolder, to: temp)
            // A copy that is not a real directory must not be published as the user's data.
            guard try fileSystem.itemKind(at: temp) == .directory else { throw MigrationError.copyIsNotDirectory }
            try fileSystem.moveItem(at: temp, to: newFolder)
            preferences.set(true, forKey: Self.folderMarkerKey)
            return .done
        } catch {
            return .failed(failure(for: error, cleaning: temp))
        }
    }

    /// Never leave a partial copy that a later run could mistake for real data; a cleanup error
    /// is appended so an orphaned copy shows up in the log.
    private func failure(for error: Error, cleaning temp: URL) -> Failure {
        var failure = Failure(error)
        do {
            try fileSystem.removeItem(at: temp)
        } catch {
            failure = Failure(
                detail: failure.detail + Self.cleanupFailedSeparator + String(describing: error),
                domain: failure.domain,
                code: failure.code
            )
        }
        return failure
    }

    private func sweepStaleTemps() -> StepResult {
        let entries: [URL]
        do {
            entries = try fileSystem.contentsOfDirectory(
                at: appSupportURL,
                includingPropertiesForKeys: nil,
                options: [],
                limit: Self.siblingListingLimit
            )
        } catch {
            return .failed(Failure(error))
        }

        var removed = false
        var failures: [Failure] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.tempPrefix) {
            do {
                try fileSystem.removeItem(at: entry)
                removed = true
            } catch {
                // Keep going: one stuck folder must not hide the others.
                failures.append(Failure(error))
            }
        }
        guard let first = failures.first else { return removed ? .done : .skipped }
        let detail = failures.map(\.detail).joined(separator: Self.detailSeparator)
        return .failed(Failure(detail: detail, domain: first.domain, code: first.code))
    }

    // MARK: - Preferences

    private func migratePreferences() -> StepResult {
        guard !preferences.bool(forKey: Self.markerKey) else { return .skipped }
        // No legacy domain means nothing can be read; leave the marker unset so a later launch retries.
        guard let legacy = legacyPreferences?.dictionaryRepresentation() else { return .skipped }

        var copied = false
        for (key, value) in legacy where isAllowed(key) && preferences.object(forKey: key) == nil {
            preferences.set(value, forKey: key)
            copied = true
        }
        preferences.set(true, forKey: Self.markerKey)
        return copied ? .done : .skipped
    }

    private func isAllowed(_ key: String) -> Bool {
        Self.allowedKeys.contains(key) || Self.allowedKeyPrefixes.contains { key.hasPrefix($0) }
    }
}
