import AppKit

/// Result containing both score and matched character indices.
struct FuzzyMatchResult {
    let score: Int
    /// Character indices (0-based) in the candidate string that matched.
    let matchedIndices: [Int]
}

/// Blazing fast fuzzy matcher using direct byte array operations.
/// Avoids slow String.Index operations for O(1) character access.
enum FuzzyMatcher {
    /// fzf-style fuzzy matching score.
    /// Returns `0` if `query` is not a subsequence of `candidate`.
    @inlinable
    static func score(query: String, candidate: String) -> Int {
        matchWithIndices(query: query, candidate: candidate).score
    }

    /// fzf-style fuzzy matching with score and match indices.
    /// Returns score `0` and empty indices if `query` is not a subsequence of `candidate`.
    @inlinable
    static func matchWithIndices(query: String, candidate: String) -> FuzzyMatchResult {
        guard !query.isEmpty else { return FuzzyMatchResult(score: 0, matchedIndices: []) }
        return matchWithIndicesUTF8(
            queryBytes: ContiguousArray(query.utf8),
            candidateBytes: ContiguousArray(candidate.utf8)
        )
    }

    /// Fast path for pre-normalized UTF-8 bytes.
    /// Both inputs must already be lowercased ASCII bytes.
    @inlinable
    static func matchWithIndices(normalizedQuery: String, normalizedCandidate: String) -> FuzzyMatchResult {
        guard !normalizedQuery.isEmpty else { return FuzzyMatchResult(score: 0, matchedIndices: []) }
        return matchWithIndicesUTF8(
            queryBytes: ContiguousArray(normalizedQuery.utf8),
            candidateBytes: ContiguousArray(normalizedCandidate.utf8)
        )
    }

    /// Ultra-fast path using pre-computed byte arrays.
    /// - Parameters:
    ///   - queryBytes: Lowercased UTF-8 bytes of query
    ///   - candidateBytes: Lowercased UTF-8 bytes of candidate
    @inlinable
    static func matchWithIndicesUTF8(
        queryBytes: ContiguousArray<UInt8>,
        candidateBytes: ContiguousArray<UInt8>
    ) -> FuzzyMatchResult {
        let queryCount = queryBytes.count
        let candidateCount = candidateBytes.count

        guard queryCount > 0, candidateCount > 0 else {
            return FuzzyMatchResult(score: 0, matchedIndices: [])
        }

        // Quick rejection: query longer than candidate
        guard queryCount <= candidateCount else {
            return FuzzyMatchResult(score: 0, matchedIndices: [])
        }

        // ASCII lowercase: a-z = 97-122, A-Z = 65-90
        // To lowercase: if 65 <= c <= 90, add 32
        @inline(__always)
        func toLower(_ c: UInt8) -> UInt8 {
            (c >= 65 && c <= 90) ? c + 32 : c
        }

        // PHASE 1: Try to find an exact contiguous substring match (case-insensitive).
        // This ensures queries like "[main]" match the exact substring rather than
        // scattered characters across the candidate.
        if let substringResult = findExactSubstring(
            queryBytes: queryBytes,
            candidateBytes: candidateBytes,
            queryCount: queryCount,
            candidateCount: candidateCount,
            toLower: toLower
        ) {
            return substringResult
        }

        // PHASE 2: Fall back to greedy subsequence matching.
        return fuzzySubsequenceMatch(
            queryBytes: queryBytes,
            candidateBytes: candidateBytes,
            queryCount: queryCount,
            candidateCount: candidateCount,
            toLower: toLower
        )
    }

    /// Finds the earliest exact contiguous substring match (case-insensitive).
    /// Returns nil if no exact substring match exists.
    @inlinable
    static func findExactSubstring(
        queryBytes: ContiguousArray<UInt8>,
        candidateBytes: ContiguousArray<UInt8>,
        queryCount: Int,
        candidateCount: Int,
        toLower: (UInt8) -> UInt8
    ) -> FuzzyMatchResult? {
        let searchLimit = candidateCount - queryCount

        // Scan for the first occurrence of the query as a contiguous substring
        outer: for startIdx in 0 ... searchLimit {
            // Check if all query bytes match starting at startIdx
            for qIdx in 0 ..< queryCount {
                let qChar = toLower(queryBytes[qIdx])
                let cChar = toLower(candidateBytes[startIdx + qIdx])
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
            if startIdx > 0 {
                let prevChar = candidateBytes[startIdx - 1]
                if prevChar == 32 || prevChar == 45 || prevChar == 95 { // ' ', '-', '_'
                    bonusScore += 15
                }
            }

            return FuzzyMatchResult(score: substringBaseScore + bonusScore, matchedIndices: matchedIndices)
        }

        return nil
    }

    /// Greedy subsequence matching (original algorithm).
    @inlinable
    static func fuzzySubsequenceMatch(
        queryBytes: ContiguousArray<UInt8>,
        candidateBytes: ContiguousArray<UInt8>,
        queryCount: Int,
        candidateCount: Int,
        toLower: (UInt8) -> UInt8
    ) -> FuzzyMatchResult {
        var queryIdx = 0
        var candidateIdx = 0
        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryCount)

        while queryIdx < queryCount, candidateIdx < candidateCount {
            let qChar = toLower(queryBytes[queryIdx])
            let cChar = toLower(candidateBytes[candidateIdx])

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
                if candidateIdx > 0 {
                    let prevChar = candidateBytes[candidateIdx - 1]
                    if prevChar == 32 || prevChar == 45 || prevChar == 95 { // ' ', '-', '_'
                        score += 15
                    }
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

// Represents a search result with a relevance score and match indices
struct SearchResult {
    let application: ApplicationInfo
    let score: Int
    /// Character indices in application.name that matched the query.
    let matchedIndices: [Int]
}

final class SearchService {
    private let indexer: ApplicationIndexer
    private var cachedQuery: ContiguousArray<UInt8> = []
    private var cachedCandidates: [ApplicationInfo] = []
    private var cachedIndexerCount: Int = 0

    init(indexer: ApplicationIndexer) {
        self.indexer = indexer
    }

    func allApplications() -> [ApplicationInfo] {
        indexer.allApplications
    }

    func resetCache() {
        cachedQuery = []
        cachedCandidates = []
        cachedIndexerCount = 0
    }

    /// Search applications using fuzzy matching
    /// - Parameter query: The search query
    /// - Returns: Sorted search results by relevance score (higher is better)
    func search(_ query: String) -> [SearchResult] {
        search(query) { false }
    }

    func search(_ query: String, isCancelled: () -> Bool) -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            resetCache()
            return []
        }

        if isCancelled() { return [] }

        // Pre-compute lowercased query bytes once
        let queryBytes = ContiguousArray(trimmedQuery.lowercased().utf8)
        let allApps = indexer.allApplications
        let candidates: [ApplicationInfo]

        // Invalidate cache if indexer data changed (app added/removed)
        let currentCount = allApps.count
        if currentCount != cachedIndexerCount {
            cachedQuery = []
            cachedCandidates = []
            cachedIndexerCount = currentCount
        }

        // Use cached candidates if query is a refinement (prefix match)
        if !cachedQuery.isEmpty, !cachedCandidates.isEmpty,
           queryBytes.count >= cachedQuery.count,
           queryBytes.prefix(cachedQuery.count).elementsEqual(cachedQuery)
        {
            candidates = cachedCandidates
        } else {
            candidates = allApps
        }

        if isCancelled() { return [] }

        var results: [SearchResult] = []
        results.reserveCapacity(min(candidates.count, 50))

        for app in candidates {
            if isCancelled() { return [] }

            let match = FuzzyMatcher.matchWithIndicesUTF8(
                queryBytes: queryBytes,
                candidateBytes: app.normalizedNameBytes
            )

            if match.score > 0 {
                results.append(SearchResult(application: app, score: match.score, matchedIndices: match.matchedIndices))
            }
        }

        if isCancelled() { return [] }

        results.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.application.name < $1.application.name
        }

        cachedQuery = queryBytes
        cachedCandidates = results.map(\.application)

        return results
    }
}
