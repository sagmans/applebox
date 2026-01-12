import AppKit

struct ClipboardItem: Codable {
    let content: String
    let timestamp: Date

    init(content: String) {
        self.content = content
        self.timestamp = Date()
    }
}

class ClipboardManager {
    private let maxHistoryCount = 50
    private var history: [ClipboardItem] = []
    private let pasteboard: PasteboardProtocol
    private let fileSystem: FileSystemProtocol
    private var lastChangeCount: Int = 0
    private var monitoringTimer: Timer?
    private let storageURL: URL

    // File location for persistent storage
    private let fileName = "clipboard_history.json"

    init(pasteboard: PasteboardProtocol = SystemPasteboard(), fileSystem: FileSystemProtocol = SystemFileManager()) {
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

        // Load existing history
        loadHistory()

        // Start monitoring
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    func getHistory() -> [ClipboardItem] {
        return history
    }

    func searchHistory(query: String) -> [ClipboardItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return history }

        let scored = history.enumerated().compactMap { index, item -> (index: Int, item: ClipboardItem, score: Int)? in
            let score = FuzzyMatcher.score(query: trimmedQuery, candidate: item.content)
            guard score > 0 else { return nil }
            return (index: index, item: item, score: score)
        }

        return scored
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                // Preserve recency (history is already most-recent-first)
                return $0.index < $1.index
            }
            .map { $0.item }
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

    private func checkForChanges() {
        guard pasteboard.changeCount != lastChangeCount else { return }

        lastChangeCount = pasteboard.changeCount

        // Only capture plain text
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        // Ignore duplicate consecutive copies
        if let lastItem = history.first, lastItem.content == text {
            return
        }

        // Add new item to beginning of history
        let newItem = ClipboardItem(content: text)
        history.insert(newItem, at: 0)

        // Limit history to maxHistoryCount items
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }

        // Persist to disk
        saveHistory()

        print("ClipboardManager: Captured new item (\(text.count) characters)")
    }

    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            _ = fileSystem.createFile(atPath: storageURL.path, contents: data, attributes: nil)
            print("ClipboardManager: Saved \(history.count) items to disk")
        } catch {
            print("ClipboardManager: Failed to save history - \(error.localizedDescription)")
        }
    }

    private func loadHistory() {
        guard fileSystem.fileExists(atPath: storageURL.path) else {
            print("ClipboardManager: No existing history found")
            return
        }

        guard let data = fileSystem.contents(atPath: storageURL.path) else {
            print("ClipboardManager: Failed to read history file")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            history = try decoder.decode([ClipboardItem].self, from: data)
            print("ClipboardManager: Loaded \(history.count) items from disk")
        } catch {
            print("ClipboardManager: Failed to load history - \(error.localizedDescription)")
        }
    }
}
