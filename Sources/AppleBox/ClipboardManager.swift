import AppKit
import OSLog

/// Content type for clipboard items
enum ClipboardContentType: String, Codable {
    case text
    case image
}

struct ClipboardItem: Codable {
    let content: String
    let timestamp: Date
    let contentType: ClipboardContentType
    /// Base64-encoded image data (PNG format) when contentType is .image
    let imageData: String?

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

    /// Returns the decoded NSImage for image content types
    func getImage() -> NSImage? {
        guard contentType == .image, let base64 = imageData,
              let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}

final class ClipboardManager {
    private let maxHistoryCount = 50

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
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Try to capture image first (PNG or TIFF)
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let newBase64 = imageData.base64EncodedString()

            var shouldSave = false
            historyQueue.sync {
                if let lastItem = history.first, lastItem.contentType == .image, lastItem.imageData == newBase64 {
                    return
                }

                history.insert(ClipboardItem(imageData: imageData), at: 0)
                if history.count > maxHistoryCount {
                    history = Array(history.prefix(maxHistoryCount))
                }
                shouldSave = true
            }

            if shouldSave {
                postHistoryUpdated()
                saveHistoryAsync()
            }
            return
        }

        // Capture plain text
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        var shouldSave = false
        historyQueue.sync {
            if let lastItem = history.first, lastItem.contentType == .text, lastItem.content == text {
                return
            }

            history.insert(ClipboardItem(content: text), at: 0)
            if history.count > maxHistoryCount {
                history = Array(history.prefix(maxHistoryCount))
            }
            shouldSave = true
        }

        if shouldSave {
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
        let snapshot = getHistory()
        persistenceQueue.async { [snapshot, storageURL, fileSystem, logger] in
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
                self.history = loaded
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
