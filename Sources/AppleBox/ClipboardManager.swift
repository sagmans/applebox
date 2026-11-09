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

final class ClipboardManager {
    private let maxHistoryCount = 50

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
    private var lastChangeCount: Int = 0
    private var monitoringTimer: Timer?
    private let storageURL: URL

    private let historyQueue = DispatchQueue(label: "applebox.clipboard.history", qos: .userInitiated)
    private var history: [ClipboardItem] = []

    private let persistenceQueue = DispatchQueue(label: "applebox.clipboard.persistence", qos: .utility)

    /// File location for persistent storage
    private let fileName = "clipboard_history.json"

    /// Drain any queued persistence work. Useful for deterministic tests and app shutdown.
    func flushPendingPersistence() {
        persistenceQueue.sync {}
    }

    init(
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        fileSystem: FileSystemProtocol = SystemFileManager(),
        loadSynchronously: Bool = true
    ) {
        self.pasteboard = pasteboard
        self.fileSystem = fileSystem

        // Store in Application Support directory
        let appSupportURL = fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupportURL.appendingPathComponent("AppleBox", isDirectory: true)

        // Create directory if it doesn't exist
        if !fileSystem.fileExists(atPath: appDirectory.path) {
            try? fileSystem.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }

        storageURL = appDirectory.appendingPathComponent(fileName)

        if loadSynchronously {
            loadHistorySync()
        } else {
            loadHistoryAsync()
        }

        // Start monitoring
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    func getHistory() -> [ClipboardItem] {
        historyQueue.sync { history }
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

        let scored = snapshot.enumerated().compactMap { index, item -> (index: Int, match: ClipboardSearchMatch)? in
            let result = FuzzyMatcher.matchWithIndices(query: trimmedQuery, candidate: item.content)
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

        // Check for changes every 0.5 seconds
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    private func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    /// Polls the pasteboard once. The monitoring timer calls this every 0.5 s;
    /// tests call it directly so they do not race the timer.
    func checkForChanges() {
        let change = pasteboard.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        guard let types = pasteboard.types,
              excludedTypes.isDisjoint(with: types),
              pasteboard.changeCount == change else { return }

        let item: ClipboardItem
        // Keep the richest supported representation when the pasteboard offers both.
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            item = ClipboardItem(imageData: imageData)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            item = ClipboardItem(content: text)
        } else {
            return
        }

        // Discard a payload if its privacy check belonged to a different clipboard change.
        guard pasteboard.changeCount == change else { return }
        record(item)
    }

    /// Check for duplicates and insert on the same queue to keep history ordered.
    private func record(_ item: ClipboardItem) {
        let didInsert = historyQueue.sync {
            if history.first?.hasSamePayload(as: item) == true {
                return false
            }

            history.insert(item, at: 0)
            if history.count > maxHistoryCount {
                history = Array(history.prefix(maxHistoryCount))
            }
            return true
        }

        if didInsert {
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
            // A save queued during startup must include history loaded ahead of it.
            let snapshot = getHistory()
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)

                // Atomic write to reduce risk of corrupted/partial files.
                try fileSystem.write(data, to: storageURL, options: [.atomic])
            } catch {
                // Best-effort persistence, but keep a breadcrumb for debugging.
                logger.error("Failed to persist clipboard history: \(String(describing: error))")
            }
        }
    }

    private func loadHistoryAsync() {
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            let loaded = loadHistoryFromDisk()
            historyQueue.sync {
                // Copies captured during startup are newer than everything on disk.
                let duplicateBoundary = self.history.last.map { loaded.first?.hasSamePayload(as: $0) == true } ?? false
                let olderItems = duplicateBoundary ? loaded.dropFirst() : loaded[...]
                self.history.append(contentsOf: olderItems.prefix(self.maxHistoryCount - self.history.count))
            }
            postHistoryUpdated()
        }
    }

    private func loadHistorySync() {
        let loaded = loadHistoryFromDisk()
        historyQueue.sync {
            history = loaded
        }
    }

    private func loadHistoryFromDisk() -> [ClipboardItem] {
        guard fileSystem.fileExists(atPath: storageURL.path), let data = fileSystem.contents(atPath: storageURL.path) else { return [] }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ClipboardItem].self, from: data)
        } catch {
            return []
        }
    }
}
