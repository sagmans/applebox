import AppKit
import Synchronization

/// Result containing both score and matched character indices.
nonisolated struct FuzzyMatchResult: Sendable {
    let score: Int
    /// Character indices (0-based) in the candidate string that matched.
    let matchedIndices: [Int]
}

/// Value types below cross the search and indexing queues, so they are nonisolated and Sendable.
/// Keep the original character positions when folding changes a name or clip.
nonisolated enum FuzzyText: Sendable {
    case ascii(ContiguousArray<UInt8>)
    case unicode(ContiguousArray<Character>, sourceOffsets: ContiguousArray<Int>)

    private static let asciiLimit: UInt8 = 128
    private static let carriageReturn: UInt8 = 13
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
    private static let dotlessI = "ı"
    private static let foldedI = "i"

    init(_ text: String) {
        // CRLF is a single Swift character, so byte positions can differ even in ASCII text.
        if text.utf8.allSatisfy({ $0 < Self.asciiLimit && $0 != Self.carriageReturn }) {
            self = .ascii(ContiguousArray(text.lowercased().utf8))
            return
        }

        var characters: ContiguousArray<Character> = []
        var offsets: ContiguousArray<Int> = []
        for (index, character) in text.enumerated() {
            if let ascii = character.asciiValue {
                characters.append(Character(UnicodeScalar(FuzzyMatcher.asciiLowercase(ascii))))
                offsets.append(index)
                continue
            }
            let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Self.foldingLocale)
            // Find Turkish I variants across keyboard layouts without changing ASCII ranking by locale.
            let normalized = folded == Self.dotlessI ? Self.foldedI : folded
            for unit in normalized {
                characters.append(unit)
                offsets.append(index)
            }
        }
        self = .unicode(characters, sourceOffsets: offsets)
    }

    var characters: ContiguousArray<Character> {
        switch self {
        case let .ascii(bytes): ContiguousArray(bytes.map { Character(UnicodeScalar($0)) })
        case let .unicode(characters, _): characters
        }
    }

    func hasPrefix(_ prefix: Self) -> Bool {
        if case let .ascii(bytes) = self, case let .ascii(prefixBytes) = prefix {
            return bytes.starts(with: prefixBytes)
        }
        return characters.starts(with: prefix.characters)
    }
}

/// Use the same scoring for ASCII bytes and folded Unicode characters.
nonisolated enum FuzzyMatcher {
    /// fzf-style fuzzy matching score.
    /// Returns `0` if `query` is not a subsequence of `candidate`.
    static func score(query: String, candidate: String) -> Int {
        matchWithIndices(query: query, candidate: candidate).score
    }

    /// fzf-style fuzzy matching with score and match indices.
    /// Returns score `0` and empty indices if `query` is not a subsequence of `candidate`.
    static func matchWithIndices(query: String, candidate: String) -> FuzzyMatchResult {
        matchWithIndices(query: FuzzyText(query), candidate: FuzzyText(candidate))
    }

    static func matchWithIndices(query: FuzzyText, candidate: FuzzyText) -> FuzzyMatchResult {
        if case let .ascii(candidateBytes) = candidate {
            switch query {
            case let .ascii(queryBytes):
                return matchWithIndicesUTF8(queryBytes: queryBytes, candidateBytes: candidateBytes)
            case let .unicode(characters, _):
                let queryBytes = ContiguousArray(characters.compactMap(\.asciiValue))
                guard queryBytes.count == characters.count else {
                    return FuzzyMatchResult(score: 0, matchedIndices: [])
                }
                return matchWithIndicesUTF8(queryBytes: queryBytes, candidateBytes: candidateBytes)
            }
        }

        let match = matchUnits(
            query: query.characters,
            candidate: candidate.characters,
            normalize: { $0 },
            isBoundary: { $0 == " " || $0 == "-" || $0 == "_" }
        )
        guard case let .unicode(_, offsets) = candidate else { return match }
        var originalIndices: [Int] = []
        for index in match.matchedIndices where originalIndices.last != offsets[index] {
            originalIndices.append(offsets[index])
        }
        return FuzzyMatchResult(score: match.score, matchedIndices: originalIndices)
    }

    /// Ultra-fast path using pre-computed byte arrays.
    /// - Parameters:
    ///   - queryBytes: Lowercased UTF-8 bytes of query
    ///   - candidateBytes: Lowercased UTF-8 bytes of candidate
    static func matchWithIndicesUTF8(
        queryBytes: ContiguousArray<UInt8>,
        candidateBytes: ContiguousArray<UInt8>
    ) -> FuzzyMatchResult {
        matchUnits(query: queryBytes, candidate: candidateBytes, normalize: asciiLowercase, isBoundary: asciiWordBoundary)
    }

    fileprivate static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    private static func asciiWordBoundary(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 45 || byte == 95
    }

    private static func matchUnits<Unit: Equatable>(
        query: ContiguousArray<Unit>,
        candidate: ContiguousArray<Unit>,
        normalize: (Unit) -> Unit,
        isBoundary: (Unit) -> Bool
    ) -> FuzzyMatchResult {
        guard !query.isEmpty, query.count <= candidate.count else {
            return FuzzyMatchResult(score: 0, matchedIndices: [])
        }

        // PHASE 1: Try to find an exact contiguous substring match (case-insensitive).
        // This ensures queries like "[main]" match the exact substring rather than
        // scattered characters across the candidate.
        if let substringResult = findExactSubstring(
            query: query,
            candidate: candidate,
            normalize: normalize,
            isBoundary: isBoundary
        ) {
            return substringResult
        }

        // PHASE 2: Fall back to greedy subsequence matching.
        return fuzzySubsequenceMatch(
            query: query,
            candidate: candidate,
            normalize: normalize,
            isBoundary: isBoundary
        )
    }

    /// Finds the earliest exact contiguous substring match (case-insensitive).
    /// Returns nil if no exact substring match exists.
    private static func findExactSubstring<Unit: Equatable>(
        query: ContiguousArray<Unit>,
        candidate: ContiguousArray<Unit>,
        normalize: (Unit) -> Unit,
        isBoundary: (Unit) -> Bool
    ) -> FuzzyMatchResult? {
        let queryCount = query.count
        let searchLimit = candidate.count - queryCount

        // Scan for the first occurrence of the query as a contiguous substring
        outer: for startIdx in 0 ... searchLimit {
            // Check if all query bytes match starting at startIdx
            for qIdx in 0 ..< queryCount {
                let qChar = normalize(query[qIdx])
                let cChar = normalize(candidate[startIdx + qIdx])
                if qChar != cChar {
                    continue outer
                }
            }

            // Found exact substring match at startIdx
            // Build contiguous indices
            var matchedIndices: [Int] = []
            matchedIndices.reserveCapacity(queryCount)
            for i in 0 ..< queryCount {
                matchedIndices.append(startIdx + i)
            }

            // Calculate score for the contiguous match
            // Use a large base score to ensure substring matches outrank fuzzy-only matches
            let substringBaseScore = 1_000_000

            // Add standard scoring bonuses
            var bonusScore = 10 * queryCount // Base per-character score

            // Consecutive bonus: all characters are consecutive
            // Formula: 5 * (1 + 2 + ... + (n-1)) = 5 * (n-1)*n/2
            if queryCount > 1 {
                bonusScore += 5 * (queryCount - 1) * queryCount / 2
            }

            // Start of string bonus
            if startIdx == 0 {
                bonusScore += 20
            }

            // Word boundary bonus (after space, dash, underscore)
            if startIdx > 0, isBoundary(candidate[startIdx - 1]) {
                bonusScore += 15
            }

            return FuzzyMatchResult(score: substringBaseScore + bonusScore, matchedIndices: matchedIndices)
        }

        return nil
    }

    /// Greedy subsequence matching (original algorithm).
    private static func fuzzySubsequenceMatch<Unit: Equatable>(
        query: ContiguousArray<Unit>,
        candidate: ContiguousArray<Unit>,
        normalize: (Unit) -> Unit,
        isBoundary: (Unit) -> Bool
    ) -> FuzzyMatchResult {
        let queryCount = query.count
        let candidateCount = candidate.count
        var queryIdx = 0
        var candidateIdx = 0
        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryCount)

        while queryIdx < queryCount, candidateIdx < candidateCount {
            let qChar = normalize(query[queryIdx])
            let cChar = normalize(candidate[candidateIdx])

            if qChar == cChar {
                matchedIndices.append(candidateIdx)
                score += 10

                if previousCharWasMatch {
                    consecutiveMatches += 1
                    score += 5 * consecutiveMatches
                } else {
                    consecutiveMatches = 0
                }

                // Start of string bonus
                if candidateIdx == 0 {
                    score += 20
                }

                // Word boundary bonus (after space, dash, underscore)
                if candidateIdx > 0, isBoundary(candidate[candidateIdx - 1]) {
                    score += 15
                }

                queryIdx += 1
                previousCharWasMatch = true
            } else {
                previousCharWasMatch = false
            }

            candidateIdx += 1
        }

        // Check if all query characters were matched
        if queryIdx < queryCount {
            return FuzzyMatchResult(score: 0, matchedIndices: [])
        }

        return FuzzyMatchResult(score: score, matchedIndices: matchedIndices)
    }
}

/// Represents a search result with a relevance score and match indices
nonisolated struct SearchResult: Sendable {
    let application: ApplicationInfo
    let score: Int
    /// Character indices in application.name that matched the query.
    let matchedIndices: [Int]
}

/// Searches run off the main actor so typing never waits on matching; the lock exists because the
/// refinement cache is shared by every in-flight search and a superseded one may still be unwinding
/// while its replacement starts.
final nonisolated class SearchService: @unchecked Sendable {
    private let indexer: ApplicationIndexer
    private let lock = NSLock()
    private var cachedQuery: FuzzyText?
    private var cachedCandidates: [ApplicationInfo] = []
    private var cachedIndexerRevision: UInt64?
    /// Bumped by `resetCache()` without the lock. The main actor calls the reset, and taking the lock
    /// there would wait for a cancelled background search to reach its next cancellation check.
    private let resetGeneration = Atomic<UInt64>(0)
    /// The reset generation the cache was filled under; a different current value means it is stale.
    private var cachedResetGeneration: UInt64 = 0

    init(indexer: ApplicationIndexer) {
        self.indexer = indexer
    }

    func allApplications() -> [ApplicationInfo] {
        indexer.allApplications
    }

    /// Marks the cache stale for the next search instead of clearing it in place, so the caller never
    /// waits on a search that holds the lock.
    func resetCache() {
        resetGeneration.add(1, ordering: .releasing)
    }

    /// The cache is only valid inside `lock`; this unlocked variant lets a search that already holds
    /// the lock reset it without deadlocking on the non-recursive mutex.
    private func clearCache() {
        cachedQuery = nil
        cachedCandidates = []
        cachedIndexerRevision = nil
    }

    /// Search applications using fuzzy matching
    /// - Parameter query: The search query
    /// - Returns: Sorted search results by relevance score (higher is better)
    func search(_ query: String) -> [SearchResult] {
        search(query) { false }
    }

    func search(_ query: String, isCancelled: () -> Bool) -> [SearchResult] {
        lock.withLock { searchLocked(query, isCancelled: isCancelled) }
    }

    private func searchLocked(_ query: String, isCancelled: () -> Bool) -> [SearchResult] {
        let generation = resetGeneration.load(ordering: .acquiring)
        if generation != cachedResetGeneration {
            clearCache()
            cachedResetGeneration = generation
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clearCache()
            return []
        }

        if isCancelled() {
            return []
        }

        let query = FuzzyText(trimmedQuery)
        let snapshot = indexer.snapshot
        let candidates: [ApplicationInfo]

        // A rename or move can change the candidate set without changing its size.
        if snapshot.revision != cachedIndexerRevision {
            cachedQuery = nil
            cachedCandidates = []
            cachedIndexerRevision = snapshot.revision
        }

        // Use cached candidates if query is a refinement (prefix match)
        if let cachedQuery, !cachedCandidates.isEmpty, query.hasPrefix(cachedQuery) {
            candidates = cachedCandidates
        } else {
            candidates = snapshot.applications
        }

        if isCancelled() {
            return []
        }

        var results: [SearchResult] = []
        results.reserveCapacity(min(candidates.count, 50))

        for app in candidates {
            if isCancelled() {
                return []
            }

            let displayMatch = FuzzyMatcher.matchWithIndices(query: query, candidate: app.searchableName)
            let filenameScore = app.searchableFilename.map {
                FuzzyMatcher.matchWithIndices(query: query, candidate: $0).score
            } ?? 0
            let score = max(displayMatch.score, filenameScore)

            if score > 0 {
                // Filename offsets do not address the localized string shown in the results list.
                results.append(SearchResult(application: app, score: score, matchedIndices: displayMatch.matchedIndices))
            }
        }

        if isCancelled() {
            return []
        }

        results.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.application.isOrderedBefore($1.application)
        }

        // A reset during this search means the session it belonged to is over; its results must not
        // seed the next session's refinements.
        if resetGeneration.load(ordering: .acquiring) == generation {
            cachedQuery = query
            cachedCandidates = results.map(\.application)
        }

        return results
    }
}
