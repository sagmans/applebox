import AppKit
import ImageIO
import OSLog

/// Content type for clipboard items
enum ClipboardContentType: String, Codable {
    case text
    case image
}

struct ClipboardItem: Codable {
    /// Distinguish repeated copies without changing the on-disk history format.
    let id = UUID()
    let content: String
    let timestamp: Date
    let contentType: ClipboardContentType
    /// Keep the original bytes so replay does not change the image encoding.
    let imageData: String?

    private enum CodingKeys: String, CodingKey {
        case content, timestamp, contentType, imageData
    }

    init(content: String) {
        self.content = content
        timestamp = Date()
        contentType = .text
        imageData = nil
    }

    init(imageData: Data) {
        content = "[Image]"
        timestamp = Date()
        contentType = .image
        self.imageData = imageData.base64EncodedString()
    }

    /// Deduplicate neighboring copies without conflating distinct history entries.
    func hasSamePayload(as other: ClipboardItem) -> Bool {
        guard contentType == other.contentType else { return false }
        return contentType == .text ? content == other.content : imageData == other.imageData
    }

    /// Returns the decoded NSImage for image content types
    func getImage() -> NSImage? {
        imageBytes.flatMap(NSImage.init(data:))
    }

    /// Identify the original format because older history stores only the bytes.
    func imageRepresentation() -> (data: Data, type: NSPasteboard.PasteboardType)? {
        guard let data = imageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let identifier = CGImageSourceGetType(source) else { return nil }

        let type = NSPasteboard.PasteboardType(identifier as String)
        guard type == .png || type == .tiff else { return nil }
        return (data, type)
    }

    private var imageBytes: Data? {
        guard contentType == .image, let imageData else { return nil }
        return Data(base64Encoded: imageData)
    }
}

private enum ClipboardHistoryLimits {
    private static let kibibyte = 1024
    private static let mebibyte = kibibyte * kibibyte
    private static let maximumJSONEscapeBytes = 6
    private static let secondsPerDay: TimeInterval = 24 * 60 * 60
    private static let retentionDays: TimeInterval = 30
    private static let base64GroupWidth = 4
    private static let base64GroupBytes = 3
    private static let maximumBase64Padding = 2
    static let itemCount = 50
    static let textBytes = 256 * kibibyte
    static let imageBytes = 8 * mebibyte
    private static let base64ImageBytes = base64GroupWidth * ((imageBytes + base64GroupBytes - 1) / base64GroupBytes)
    private static let payloadBudget = 32 * mebibyte
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
        guard let image = item.imageData else { return textCost }
        let encodedSize = image.utf8.count
        guard encodedSize <= base64ImageBytes, encodedSize.isMultiple(of: base64GroupWidth) else { return nil }
        let padding = image.utf8.suffix(base64GroupWidth).reversed().prefix(while: { $0 == UInt8(ascii: "=") }).count
        let decodedSize = encodedSize / base64GroupWidth * base64GroupBytes - padding
        guard padding <= maximumBase64Padding, decodedSize <= imageBytes else { return nil }
        return textCost + encodedSize
    }
}

private enum ClipboardStorageError: Error {
    case unavailable
    case archiveTooLarge
}

final class ClipboardManager {
    static let readAccessDidChange = Notification.Name("applebox.clipboardReadAccess.didChange")
    private static let capturePausedKey = "ClipboardCapturePaused"
    private static let privateDirectoryMode = 0o700
    private static let captureInterval: TimeInterval = 0.2
    private static let captureTolerance: TimeInterval = 0.02

    /// Keep private, temporary, and generated content out of user copy history.
    private let excludedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        .generatedClipboardContent,
    ]

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox",
        category: "clipboard"
    )

    private let pasteboard: PasteboardProtocol
    private let fileSystem: FileSystemProtocol
    private let capturePreferences: UserDefaults?
    private(set) var isCapturePaused: Bool
    private var lastChangeCount: Int = 0
    private(set) var readAccess: ClipboardReadAccess
    private var monitoringTimer: Timer?
    private var expiryTimer: Timer?
    private let storageURL: URL?

    private let historyQueue = DispatchQueue(label: "applebox.clipboard.history", qos: .userInitiated)
    private var history: [ClipboardItem] = []

    private let persistenceQueue = DispatchQueue(label: "applebox.clipboard.persistence", qos: .utility)
    private var storageWritesAllowed = true

    /// File location for persistent storage
    private let fileName = "clipboard_history.json"

    /// Drain any queued persistence work. Useful for deterministic tests and app shutdown.
    func flushPendingPersistence() {
        persistenceQueue.sync {}
    }

    init(
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        fileSystem: FileSystemProtocol = SystemFileManager(),
        capturePreferences: UserDefaults? = nil,
        loadSynchronously: Bool = true
    ) {
        self.pasteboard = pasteboard
        readAccess = pasteboard.readAccess
        self.fileSystem = fileSystem
        self.capturePreferences = capturePreferences
        isCapturePaused = capturePreferences?.bool(forKey: Self.capturePausedKey) ?? false

        // Store in Application Support directory
        storageURL = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppleBox", isDirectory: true)
            .appendingPathComponent(fileName)
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
            self?.pruneExpiredHistory()
        }
    }

    deinit {
        stopMonitoring()
        expiryTimer?.invalidate()
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

    func removeHistory(_ removal: HistoryRemoval, completion: @escaping (Bool) -> Void) {
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
                // Copies arriving during the write have different identities and must survive it.
                historyQueue.sync { history.removeAll { removedIDs.contains($0.id) } }
                postHistoryUpdated()
                DispatchQueue.main.async { completion(true) }
            } catch {
                logStorageFailure(error, operation: "remove")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Restart the monitor from the current change count so paused copies stay excluded.
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
    struct ClipboardSearchMatch {
        let item: ClipboardItem
        let score: Int
        let matchedIndices: [Int]
    }

    func searchHistory(query: String) -> [ClipboardItem] {
        searchHistoryWithMatches(query: query).map(\.item)
    }

    /// Search history returning full match results (score + indices) to avoid duplicate fuzzy matching.
    func searchHistoryWithMatches(query: String) -> [ClipboardSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = getHistory()

        guard !trimmedQuery.isEmpty else {
            return snapshot.map { ClipboardSearchMatch(item: $0, score: 0, matchedIndices: []) }
        }

        let query = FuzzyText(trimmedQuery)
        let scored = snapshot.enumerated().compactMap { index, item -> (index: Int, match: ClipboardSearchMatch)? in
            let result = FuzzyMatcher.matchWithIndices(query: query, candidate: FuzzyText(item.content))
            guard result.score > 0 else { return nil }
            return (index: index, match: ClipboardSearchMatch(item: item, score: result.score, matchedIndices: result.matchedIndices))
        }

        return scored
            .sorted {
                if $0.match.score != $1.match.score {
                    return $0.match.score > $1.match.score
                }
                // Preserve recency (history is already most-recent-first)
                return $0.index < $1.index
            }
            .map(\.match)
    }

    // MARK: - Private Methods

    private func startMonitoring() {
        // Initialize last change count
        lastChangeCount = pasteboard.changeCount

        let timer = Timer(timeInterval: Self.captureInterval, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        // Coalesce idle wakeups while still capturing copies made during menu tracking.
        timer.tolerance = Self.captureTolerance
        RunLoop.main.add(timer, forMode: .common)
        monitoringTimer = timer
    }

    private func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    /// Allow tests to exercise one capture without depending on the timer's phase.
    func checkForChanges() {
        guard !isCapturePaused else { return }
        let change = pasteboard.changeCount
        let previouslyDenied = readAccess == .denied
        refreshReadAccess()
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        // Advance the cursor while denied so recovery cannot import copies from that period.
        guard !previouslyDenied, readAccess != .denied,
              let types = pasteboard.types,
              excludedTypes.isDisjoint(with: types),
              pasteboard.changeCount == change else { return }

        // Discard a payload if its privacy check belonged to a different clipboard change.
        guard let item = readSupportedClipboardItem(), pasteboard.changeCount == change else { return }
        record(item)
    }

    private func readSupportedClipboardItem() -> ClipboardItem? {
        // Check the raw image size before allocating its base64 representation.
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard image.count <= ClipboardHistoryLimits.imageBytes else { return nil }
            return ClipboardItem(imageData: image)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty,
              text.utf8.count <= ClipboardHistoryLimits.textBytes else { return nil }
        return ClipboardItem(content: text)
    }

    private func refreshReadAccess() {
        let access = pasteboard.readAccess
        guard access != readAccess else { return }
        readAccess = access
        NotificationCenter.default.post(name: Self.readAccessDidChange, object: self)
    }

    /// Check for duplicates and insert on the same queue to keep history ordered.
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
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("applebox.clipboardHistory.didUpdate"), object: nil)
        }
    }

    private func saveHistoryAsync() {
        persistenceQueue.async { [self] in
            guard storageWritesAllowed else { return }
            // A save queued during startup must include history loaded ahead of it.
            do {
                try persistHistory(getHistory())
            } catch {
                logStorageFailure(error, operation: "save")
            }
        }
    }

    private func persistHistory(_ snapshot: [ClipboardItem], replaceUnreadableArchive: Bool = false) throws {
        // Only an explicitly confirmed clear can replace an unreadable archive.
        guard storageWritesAllowed || replaceUnreadableArchive, let storageURL else { throw ClipboardStorageError.unavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= ClipboardHistoryLimits.archiveReadLimit else { throw ClipboardStorageError.archiveTooLarge }
        try fileSystem.writePrivateFile(data, to: storageURL)
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

    private func loadHistoryFromDisk() -> (items: [ClipboardItem], pruned: Bool) {
        guard storageWritesAllowed, let storageURL else { return ([], false) }

        do {
            guard let data = try fileSystem.readPrivateFile(at: storageURL, maximumBytes: ClipboardHistoryLimits.archiveReadLimit) else {
                return ([], false)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode([ClipboardItem].self, from: data)
            let retained = ClipboardHistoryLimits.retained(stored)
            return (retained, retained.count != stored.count)
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
