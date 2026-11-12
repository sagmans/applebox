import AppKit
import ImageIO
import OSLog

/// Content type for clipboard items
nonisolated enum ClipboardContentType: String, Codable, Sendable {
    case text
    case image
}

nonisolated struct ClipboardItem: Decodable, Sendable {
    /// Distinguish repeated copies, and name the clip's image file in `ClipboardImageStore`, so it is
    /// archived and survives a restart. Archives written before it existed get a fresh id on load.
    let id: UUID
    let content: String
    let timestamp: Date
    let contentType: ClipboardContentType
    /// The original image bytes, so replay does not change the image encoding. Held as a file reference
    /// once saved, not as bytes, because history keeps every image for the whole run.
    let image: ClipboardImagePayload?
    /// Bundle id of the app the clip came from, so the preview can say where it was copied. The writer's
    /// own `org.nspasteboard.source` declaration wins; without one it is the frontmost app when the poll
    /// noticed the change, which can be wrong if focus moved within one poll interval or a background
    /// tool wrote the clipboard. Metadata only; optional because history saved by earlier versions has none.
    let sourceBundleID: String?

    /// Keys of the record shape that `init(from:)` reads, where `imageData` holds the image as Base64.
    private enum CodingKeys: String, CodingKey {
        case content, timestamp, contentType, imageData, sourceBundleID
    }

    init(content: String, sourceBundleID: String? = nil) {
        id = UUID()
        self.content = content
        timestamp = Date()
        contentType = .text
        image = nil
        self.sourceBundleID = sourceBundleID
    }

    init(imageData: Data, sourceBundleID: String? = nil) {
        id = UUID()
        content = "[Image]"
        timestamp = Date()
        contentType = .image
        image = ClipboardImagePayload(bytes: imageData)
        self.sourceBundleID = sourceBundleID
    }

    /// Rebuilds a clip read back from the archive, keeping its id so its image file stays attached.
    init(id: UUID, content: String, timestamp: Date, contentType: ClipboardContentType, image: ClipboardImagePayload?, sourceBundleID: String?) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.contentType = contentType
        self.image = image
        self.sourceBundleID = sourceBundleID
    }

    /// The same clip after a save wrote its image file, so history stops holding the bytes.
    func withStoredImage(in store: ClipboardImageStore) -> ClipboardItem {
        guard let image, image.isInMemory else { return self }
        return ClipboardItem(id: id, content: content, timestamp: timestamp, contentType: contentType, image: image.storedCopy(in: store, id: id), sourceBundleID: sourceBundleID)
    }

    /// Decoded by hand so an archive written before `sourceBundleID` existed still loads; a missing key
    /// must mean "unknown source", never a failed load that would drop the user's whole history.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        contentType = try container.decode(ClipboardContentType.self, forKey: .contentType)
        // Text that is not Base64 leaves the clip without an image, which retention then drops.
        image = try container.decodeIfPresent(String.self, forKey: .imageData)
            .flatMap { Data(base64Encoded: $0) }
            .map(ClipboardImagePayload.init(bytes:))
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
    }

    /// Deduplicate neighboring copies without conflating distinct history entries.
    func hasSamePayload(as other: ClipboardItem) -> Bool {
        guard contentType == other.contentType else { return false }
        guard contentType == .image else { return content == other.content }
        guard let image, let otherImage = other.image else { return false }
        return image.hasSameBytes(as: otherImage)
    }

    /// Identify the original format because older history stores only the bytes. Throws when the image
    /// file cannot be read, so replay can report it instead of pasting nothing.
    func imageRepresentation() throws -> (data: Data, type: NSPasteboard.PasteboardType)? {
        guard let data = try imageBytes(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let identifier = CGImageSourceGetType(source) else { return nil }

        let type = NSPasteboard.PasteboardType(identifier as String)
        guard type == .png || type == .tiff else { return nil }
        return (data, type)
    }

    /// The original image bytes, read from the clip's image file when it is saved. Internal so
    /// persistence can write them and the image cache can decode them.
    func imageBytes() throws -> Data? {
        guard contentType == .image else { return nil }
        return try image?.bytes()
    }
}

/// Retention rules of the history. Internal, not private, so caches that mirror the history can derive
/// their bounds from `itemCount` instead of keeping a second number that drifts.
nonisolated enum ClipboardHistoryLimits {
    private static let kibibyte = 1024
    private static let mebibyte = kibibyte * kibibyte
    private static let maximumJSONEscapeBytes = 6
    private static let secondsPerDay: TimeInterval = 24 * 60 * 60
    private static let retentionDays: TimeInterval = 30
    private static let base64GroupWidth = 4
    private static let base64GroupBytes = 3
    static let itemCount = 50
    static let textBytes = 256 * kibibyte
    static let imageBytes = 8 * mebibyte
    /// Internal so the archive load can stop reading image files once retention could keep no more.
    static let payloadBudget = 32 * mebibyte
    static let archiveReadLimit = 64 * mebibyte
    static let expirySweepInterval: TimeInterval = 60 * 60

    static func cutoff(at now: Date = Date()) -> Date {
        now.addingTimeInterval(-retentionDays * secondsPerDay)
    }

    static func retained(_ history: [ClipboardItem], at now: Date = Date()) -> [ClipboardItem] {
        var remaining = payloadBudget
        var retained: [ClipboardItem] = []
        let earliest = cutoff(at: now)
        for item in history where item.timestamp >= earliest {
            guard let cost = storageCost(of: item) else { continue }
            // Keep the newest supported clips together and evict the oldest when the budget fills.
            guard cost <= remaining, retained.count < itemCount else { break }
            retained.append(item)
            remaining -= cost
        }
        return retained
    }

    private static func storageCost(of item: ClipboardItem) -> Int? {
        let textSize = item.content.utf8.count
        guard textSize <= textBytes else { return nil }
        // Budget for JSON escaping without re-encoding history during capture or search.
        let textCost = textSize * maximumJSONEscapeBytes
        guard item.contentType == .image else { return textCost }
        // An image clip without bytes cannot be shown or pasted, so it is not kept.
        guard let byteCount = item.image?.byteCount, byteCount <= imageBytes else { return nil }
        // Costed at its Base64 size, as when images sat inline in the archive, so keeping bytes out of
        // memory does not change how many clips history keeps.
        return textCost + base64GroupWidth * ((byteCount + base64GroupBytes - 1) / base64GroupBytes)
    }
}

private nonisolated enum ClipboardStorageError: Error {
    case unavailable
    case archiveTooLarge
}

/// History and persistence run on private dispatch queues, so the type opts out of default
/// main-actor isolation and only the pasteboard and timer entry points are `@MainActor`.
/// `@unchecked Sendable` is safe because `history` is only touched through `historyQueue`,
/// `storageWritesAllowed`, `pendingSave` and `persistedImageIDs` only on `persistenceQueue` (after
/// init), and the remaining mutable state (`isCapturePaused`, `lastChangeCount`, `readAccess`, the
/// timers) only from `@MainActor` members.
final nonisolated class ClipboardManager: @unchecked Sendable {
    static let readAccessDidChange = Notification.Name("bitekey.clipboardReadAccess.didChange")
    /// Posted after history changes so views refresh without polling; shared so poster and observers cannot drift.
    static let historyDidUpdate = Notification.Name("bitekey.clipboardHistory.didUpdate")
    private static let capturePausedKey = "ClipboardCapturePaused"
    private static let privateDirectoryMode = 0o700
    /// Share of the expiry sweep interval the system may delay a sweep by. Reads already hide expired clips,
    /// so only the on-disk removal waits a few minutes against a retention of days, and the slack lets macOS
    /// fold the wakeup into one it already has; Apple's energy guide suggests at least 10%.
    private static let expiryToleranceFraction = 0.1
    /// How long a save waits for more copies. A burst of copies then costs one write, and quitting
    /// flushes the wait, so only a crash inside this window can lose the newest copies.
    private static let saveCoalescingDelay: DispatchTimeInterval = .milliseconds(500)
    /// Longest bundle id accepted from a pasteboard declaration. The source is written by other apps, so
    /// anything longer than a real bundle id is not trusted or stored.
    private static let maximumBundleIDLength = 255
    /// Characters a bundle id may contain: Apple's CFBundleIdentifier rule plus the underscore, which
    /// third-party apps ship with in practice. A declaration with others is ignored rather than shown.
    private static let bundleIDCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")

    /// How often the clipboard is polled. macOS has no change notification, so the poll runs all day;
    /// its wakeups cost energy, while each check itself costs less than a microsecond.
    private enum CapturePace {
        /// The panel is hidden nearly all day, so this rate sets the idle cost. Half a second keeps two
        /// wakeups per second at most, and the 50% tolerance lets macOS fold them into other wakeups.
        /// A slower poll widens the window in which the user switches apps before a copy is seen, so the
        /// guessed "Copied from" app is more often wrong; this rate keeps that window under a second.
        case hidden
        /// The open list should show a new copy almost at once, and the panel is open only briefly.
        /// Tolerance stays at the 10% that macOS suggests as the minimum for a timer.
        case visible

        var interval: TimeInterval {
            switch self {
            case .hidden: 0.5
            case .visible: 0.2
            }
        }

        var tolerance: TimeInterval {
            switch self {
            case .hidden: 0.25
            case .visible: 0.02
            }
        }
    }

    /// Keep private, temporary, and generated content out of user copy history.
    private let excludedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        .generatedClipboardContent,
    ]

    private let logger = Logger(
        subsystem: LogSubsystem.name,
        category: "clipboard"
    )

    private let pasteboard: PasteboardProtocol
    private let fileSystem: FileSystemProtocol
    /// Reads who has focus when a clip is captured. Injected so tests do not depend on the machine's
    /// frontmost app; the default asks the workspace, which names the app the user copied from because
    /// the launcher panel never activates Bitekey. For the same reason a copy from the launcher's own
    /// preview would be credited to the app behind it, so the preview declares Bitekey as its source.
    private let frontmostBundleID: @MainActor () -> String?
    /// Bitekey's own bundle id. A copy that names Bitekey as its source (preview text) or is made while
    /// Bitekey is in front has no meaningful origin, and crediting the launcher would be a false
    /// "Copied from".
    private let ownBundleID: String?
    private let capturePreferences: UserDefaults?
    @MainActor private(set) var isCapturePaused: Bool
    private var lastChangeCount: Int = 0
    @MainActor private(set) var readAccess: ClipboardReadAccess
    /// Picks the poll rate; kept even while paused so resuming starts at the rate the panel needs.
    @MainActor private var capturePace = CapturePace.hidden
    private var monitoringTimer: Timer?
    private var expiryTimer: Timer?
    private let storageURL: URL?
    private let imageStore: ClipboardImageStore?

    private let historyQueue = DispatchQueue(label: "bitekey.clipboard.history", qos: .userInitiated)
    private var history: [ClipboardItem] = []
    /// Search state outlives one keystroke, so it lives with the history it indexes.
    private let searchIndex = ClipSearchIndex()

    private let persistenceQueue = DispatchQueue(label: "bitekey.clipboard.persistence", qos: .utility)
    private var storageWritesAllowed = true
    /// The save waiting out `saveCoalescingDelay`; while it is set, later changes ride along with it.
    private var pendingSave: DispatchWorkItem?
    /// Image clips whose file is known to be on disk, so a save writes only new images and deletes the
    /// files of clips it no longer archives.
    private var persistedImageIDs = Set<UUID>()

    /// File location for persistent storage
    private let fileName = "clipboard_history.json"

    /// Write a coalesced save now instead of after its delay, and drain other queued persistence work.
    /// App shutdown calls it so the newest copies are not lost; tests call it for deterministic writes.
    func flushPendingPersistence() {
        persistenceQueue.sync {
            guard let save = pendingSave else { return }
            save.cancel()
            runPendingSave()
        }
    }

    @MainActor
    init(
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        fileSystem: FileSystemProtocol = SystemFileManager(),
        capturePreferences: UserDefaults? = nil,
        loadSynchronously: Bool = true,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.ownBundleID = ownBundleID
        self.pasteboard = pasteboard
        readAccess = pasteboard.readAccess
        self.fileSystem = fileSystem
        self.capturePreferences = capturePreferences
        isCapturePaused = capturePreferences?.bool(forKey: Self.capturePausedKey) ?? false

        // Store in Application Support directory
        let folder = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppDataLocation.folderName, isDirectory: true)
        storageURL = folder?.appendingPathComponent(fileName)
        imageStore = folder.map {
            ClipboardImageStore(directory: $0.appendingPathComponent(ClipboardImageStore.directoryName, isDirectory: true), fileSystem: fileSystem)
        }
        prepareStorage()

        if loadSynchronously {
            loadHistorySync()
        } else {
            loadHistoryAsync()
        }

        // Respect a previous pause before scheduling the first clipboard read.
        if !isCapturePaused {
            startMonitoring()
        }

        // Expiry continues even when the clipboard monitor is paused.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: ClipboardHistoryLimits.expirySweepInterval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, which the compiler cannot see through the Sendable block.
            MainActor.assumeIsolated { self?.pruneExpiredHistory() }
        }
        expiryTimer?.tolerance = ClipboardHistoryLimits.expirySweepInterval * Self.expiryToleranceFraction
    }

    /// Not `isolated deinit`: the compiler rejects it because the class opts out of main-actor isolation
    /// (it must, for its private queues). The last release can happen on `persistenceQueue`, because
    /// `removeHistory` holds the manager there, but a timer must be invalidated on the thread whose run
    /// loop it was added to, which is main. So the invalidation hops to main when needed.
    deinit {
        // The timers are only ever touched on main, and the hop below runs there; the manager that owned
        // them is gone, so nothing else can reach them meanwhile.
        nonisolated(unsafe) let timers = [monitoringTimer, expiryTimer].compactMap(\.self)
        guard !timers.isEmpty else { return }
        if Thread.isMainThread {
            timers.forEach { $0.invalidate() }
        } else {
            DispatchQueue.main.async { timers.forEach { $0.invalidate() } }
        }
    }

    // MARK: - Public Methods

    func getHistory() -> [ClipboardItem] {
        let earliest = ClipboardHistoryLimits.cutoff()
        return historyQueue.sync { history.filter { $0.timestamp >= earliest } }
    }

    enum HistoryRemoval {
        case item(UUID)
        case all
    }

    func removeHistory(_ removal: HistoryRemoval, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        persistenceQueue.async { [self] in
            let snapshot = getHistory()
            let removedIDs: Set<UUID>
            let replaceUnreadableArchive: Bool
            switch removal {
            case let .item(id):
                removedIDs = [id]
                replaceUnreadableArchive = false
            case .all:
                removedIDs = Set(snapshot.map(\.id))
                replaceUnreadableArchive = true
            }

            let retained = snapshot.filter { !removedIDs.contains($0.id) }
            do {
                try persistHistory(retained, replaceUnreadableArchive: replaceUnreadableArchive)
                storageWritesAllowed = true
                if case .all = removal {
                    // A clear also removes image files an unreadable archive or a crash left behind.
                    removeUnreferencedImages(keeping: persistedImageIDs)
                }
                // Copies arriving during the write have different identities and must survive it.
                historyQueue.sync { history.removeAll { removedIDs.contains($0.id) } }
                postHistoryUpdated()
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(true) } }
            } catch {
                logStorageFailure(error, operation: "remove")
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(false) } }
            }
        }
    }

    /// Restart the monitor from the current change count so paused copies stay excluded.
    @MainActor
    func toggleCapturePaused() {
        isCapturePaused.toggle()
        capturePreferences?.set(isCapturePaused, forKey: Self.capturePausedKey)
        if isCapturePaused {
            stopMonitoring()
        } else {
            refreshReadAccess()
            startMonitoring()
        }
    }

    /// Result of a clipboard search with score and matched indices.
    struct ClipboardSearchMatch: Sendable {
        let item: ClipboardItem
        let score: Int
        let matchedIndices: [Int]
    }

    func searchHistory(query: String) -> [ClipboardItem] {
        searchHistoryWithMatches(query: query).map(\.item)
    }

    /// Search history returning full match results (score + indices) to avoid duplicate fuzzy matching.
    /// `isCancelled` lets a newer keystroke stop this search: the result is then empty, and the caller
    /// is expected to discard it.
    func searchHistoryWithMatches(query: String, isCancelled: () -> Bool = { false }) -> [ClipboardSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = getHistory()

        guard !trimmedQuery.isEmpty else {
            return snapshot.map { ClipboardSearchMatch(item: $0, score: 0, matchedIndices: []) }
        }
        return searchIndex.search(trimmedQuery, in: snapshot, isCancelled: isCancelled)
    }

    /// The launcher calls this as it opens and closes, so the poll is fast only while the list is on screen.
    /// On opening, access is read again for the status line and a pending copy is taken at once: the app
    /// the user copied from is still in front, because the panel does not activate Bitekey.
    @MainActor
    func setPanelVisible(_ visible: Bool) {
        let pace: CapturePace = visible ? .visible : .hidden
        guard pace != capturePace else { return }
        capturePace = pace
        if visible {
            // Check first: it judges a pending copy by the access seen before it, so a copy made while
            // denied is never imported just because access came back as the panel opened.
            checkForChanges()
            refreshReadAccess()
        }
        guard !isCapturePaused else { return }
        // Not `startMonitoring`: that skips copies made since the last tick, and they must still be taken.
        scheduleMonitoringTimer()
    }

    // MARK: - Private Methods

    @MainActor
    private func startMonitoring() {
        // Initialize last change count
        lastChangeCount = pasteboard.changeCount
        scheduleMonitoringTimer()
    }

    @MainActor
    private func scheduleMonitoringTimer() {
        // Replaces any running timer, so a pace change or a repeated start never leaves two polling.
        monitoringTimer?.invalidate()
        let timer = Timer(timeInterval: capturePace.interval, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop, which the compiler cannot see through the Sendable block.
            MainActor.assumeIsolated { self?.checkForChanges() }
        }
        // Coalesce idle wakeups while still capturing copies made during menu tracking.
        timer.tolerance = capturePace.tolerance
        RunLoop.main.add(timer, forMode: .common)
        monitoringTimer = timer
    }

    @MainActor
    private func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    /// Allow tests to exercise one capture without depending on the timer's phase.
    @MainActor
    func checkForChanges() {
        guard !isCapturePaused else { return }
        let change = pasteboard.changeCount
        let previouslyDenied = readAccess == .denied
        // Access matters only when there is a copy to read, and the panel re-reads it on opening for its
        // status line. While denied it is still read on every tick, so recovery is seen before the next
        // copy, and that copy is kept instead of being taken for one made while denied.
        if previouslyDenied || change != lastChangeCount {
            refreshReadAccess()
        }
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        // Advance the cursor while denied so recovery cannot import copies from that period.
        guard !previouslyDenied, readAccess != .denied,
              let types = pasteboard.types,
              excludedTypes.isDisjoint(with: types),
              pasteboard.changeCount == change else { return }

        // Discard a payload if its privacy check belonged to a different clipboard change.
        guard let item = readSupportedClipboardItem(types: types), pasteboard.changeCount == change else { return }
        record(item)
    }

    @MainActor
    private func readSupportedClipboardItem(types: [NSPasteboard.PasteboardType]) -> ClipboardItem? {
        // Check the raw image size before hashing it.
        let source = captureSource(types: types)
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard image.count <= ClipboardHistoryLimits.imageBytes else { return nil }
            return ClipboardItem(imageData: image, sourceBundleID: source)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty,
              text.utf8.count <= ClipboardHistoryLimits.textBytes else { return nil }
        return ClipboardItem(content: text, sourceBundleID: source)
    }

    /// The declared source is exact, while the frontmost app is only a guess made at poll time, so a
    /// declaration wins. A declaration that is empty or malformed means the writer gave no usable origin,
    /// and guessing then would contradict it.
    @MainActor
    private func captureSource(types: [NSPasteboard.PasteboardType]) -> String? {
        let candidate = types.contains(.clipSource)
            ? pasteboard.data(forType: .clipSource).flatMap(Self.validBundleID)
            : frontmostBundleID()
        return candidate == ownBundleID ? nil : candidate
    }

    /// Other apps write the declaration, so it is checked like any untrusted input before it is stored.
    /// The raw bytes are length-checked before decoding, so an oversized value is never turned into a
    /// string or scanned.
    private static func validBundleID(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumBundleIDLength,
              let value = String(data: data, encoding: .utf8),
              value.unicodeScalars.allSatisfy(bundleIDCharacters.contains) else { return nil }
        return value
    }

    @MainActor
    private func refreshReadAccess() {
        let access = pasteboard.readAccess
        guard access != readAccess else { return }
        readAccess = access
        NotificationCenter.default.post(name: Self.readAccessDidChange, object: self)
    }

    /// Check for duplicates and insert on the same queue to keep history ordered.
    @MainActor
    private func record(_ item: ClipboardItem) {
        let didInsert = historyQueue.sync {
            if let latest = history.first, latest.timestamp >= ClipboardHistoryLimits.cutoff(), latest.hasSamePayload(as: item) {
                return false
            }

            history.insert(item, at: 0)
            history = ClipboardHistoryLimits.retained(history)
            return true
        }

        if didInsert {
            postHistoryUpdated()
            saveHistoryAsync()
        }
    }

    @MainActor
    private func pruneExpiredHistory() {
        let earliest = ClipboardHistoryLimits.cutoff()
        let changed = historyQueue.sync {
            let previousCount = history.count
            history.removeAll { $0.timestamp < earliest }
            return history.count != previousCount
        }
        if changed {
            postHistoryUpdated()
            saveHistoryAsync()
        }
    }

    private func postHistoryUpdated() {
        searchIndex.historyDidChange { [weak self] in self?.getHistory() ?? [] }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.historyDidUpdate, object: nil)
        }
    }

    /// Schedules one save for every change made within `saveCoalescingDelay`. The save reads history
    /// when it runs, so it always writes the newest state.
    private func saveHistoryAsync() {
        persistenceQueue.async { [self] in
            guard pendingSave == nil else { return }
            let save = DispatchWorkItem { [self] in runPendingSave() }
            pendingSave = save
            persistenceQueue.asyncAfter(deadline: .now() + Self.saveCoalescingDelay, execute: save)
        }
    }

    /// Runs on `persistenceQueue`, from the delayed work item or from a flush.
    private func runPendingSave() {
        pendingSave = nil
        guard storageWritesAllowed else { return }
        // A save queued during startup must include history loaded ahead of it.
        do {
            try persistHistory(getHistory())
        } catch {
            logStorageFailure(error, operation: "save")
        }
    }

    /// Writes new image files first and the archive second, and deletes stale image files last. A crash
    /// at any point leaves an archive whose images all exist; extra files are swept on the next load.
    private func persistHistory(_ snapshot: [ClipboardItem], replaceUnreadableArchive: Bool = false) throws {
        // Only an explicitly confirmed clear can replace an unreadable archive.
        guard storageWritesAllowed || replaceUnreadableArchive, let storageURL, let imageStore else { throw ClipboardStorageError.unavailable }
        let data = try ClipboardHistoryArchive.encode(snapshot)
        guard data.count <= ClipboardHistoryLimits.archiveReadLimit else { throw ClipboardStorageError.archiveTooLarge }
        // A folder deleted while the app runs took the files with it; writing every image again keeps the
        // archive from naming files that no longer exist.
        if !imageStore.directoryExists {
            persistedImageIDs.removeAll()
        }
        var archivedImageIDs = Set<UUID>()
        var writtenImageIDs = Set<UUID>()
        for item in snapshot where item.contentType == .image {
            // Checked first, so a save never reads back an image file that is already on disk.
            if persistedImageIDs.contains(item.id) {
                archivedImageIDs.insert(item.id)
                continue
            }
            // Nil or a failed read means the bytes already left memory and their file is gone or changed:
            // that clip cannot be saved again here, and it must not block the others. The next load drops
            // a missing file and reads a changed one as it then is.
            let bytes: Data?
            do {
                bytes = try item.imageBytes()
            } catch {
                logger.error("Clipboard history reread image failed: clip=\(item.id, privacy: .public) \(ClipboardImagePayload.failureSummary(error), privacy: .public)")
                continue
            }
            guard let bytes else { continue }
            try imageStore.write(bytes, for: item.id)
            archivedImageIDs.insert(item.id)
            writtenImageIDs.insert(item.id)
        }
        try fileSystem.writePrivateFile(data, to: storageURL)
        // After the archive, so a failed save leaves every new clip holding its own bytes.
        releaseImageBytes(of: writtenImageIDs, to: imageStore)
        let staleImageIDs = persistedImageIDs.subtracting(archivedImageIDs)
        persistedImageIDs = archivedImageIDs
        for id in staleImageIDs {
            do {
                try imageStore.remove(id)
            } catch {
                // The archive no longer names the file, so the next load's sweep retries the delete.
                logStorageFailure(error, operation: "remove image")
            }
        }
    }

    /// Swaps each clip's in-memory image for a reference to the file just written, so history no longer
    /// holds bytes it can read back. Matched by id, so copies that arrived during the save keep theirs.
    private func releaseImageBytes(of ids: Set<UUID>, to store: ClipboardImageStore) {
        guard !ids.isEmpty else { return }
        historyQueue.sync {
            for index in history.indices where ids.contains(history[index].id) {
                history[index] = history[index].withStoredImage(in: store)
            }
        }
    }

    /// A failed sweep only leaves unreferenced files behind, so it is logged and never blocks history.
    private func removeUnreferencedImages(keeping kept: Set<UUID>) {
        do {
            try imageStore?.removeAll(except: kept)
        } catch {
            logStorageFailure(error, operation: "sweep images")
        }
    }

    private func loadHistoryAsync() {
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            let (loaded, pruned) = loadHistoryFromDisk()
            historyQueue.sync {
                // Copies captured during startup are newer than everything on disk.
                let duplicateBoundary = self.history.last.map { loaded.first?.hasSamePayload(as: $0) == true } ?? false
                let olderItems = duplicateBoundary ? loaded.dropFirst() : loaded[...]
                self.history = ClipboardHistoryLimits.retained(self.history + olderItems)
            }
            if pruned {
                saveHistoryAsync()
            }
            postHistoryUpdated()
        }
    }

    private func loadHistorySync() {
        let (loaded, pruned) = persistenceQueue.sync { loadHistoryFromDisk() }
        historyQueue.sync {
            history = loaded
        }
        if pruned {
            saveHistoryAsync()
        }
    }

    /// `pruned` asks for a save: clips were dropped, or the archive was written by an earlier version and
    /// its inline images must move to their own files.
    private func loadHistoryFromDisk() -> (items: [ClipboardItem], pruned: Bool) {
        guard storageWritesAllowed, let storageURL, let imageStore else { return ([], false) }

        do {
            guard let data = try fileSystem.readPrivateFile(at: storageURL, maximumBytes: ClipboardHistoryLimits.archiveReadLimit) else {
                removeUnreferencedImages(keeping: [])
                return ([], false)
            }
            let restored = try ClipboardHistoryArchive.restore(ClipboardHistoryArchive.decode(data), images: imageStore)
            persistedImageIDs = restored.storedImageIDs
            removeUnreferencedImages(keeping: restored.storedImageIDs)
            let retained = ClipboardHistoryLimits.retained(restored.items)
            return (retained, restored.needsRewrite || retained.count != restored.items.count)
        } catch {
            // A failed migration must not let later copies overwrite the old archive.
            storageWritesAllowed = false
            logStorageFailure(error, operation: "load")
            return ([], false)
        }
    }

    private func prepareStorage() {
        guard let folder = storageURL?.deletingLastPathComponent() else {
            logger.error("Clipboard storage directory is unavailable")
            storageWritesAllowed = false
            return
        }
        guard !fileSystem.fileExists(atPath: folder.path) else { return }
        do {
            try fileSystem.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.privateDirectoryMode])
        } catch {
            logStorageFailure(error, operation: "prepare")
            storageWritesAllowed = false
        }
    }

    private func logStorageFailure(_ error: Error, operation: String) {
        let failure = error as NSError
        logger.error("Clipboard history \(operation, privacy: .public) failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
    }
}
