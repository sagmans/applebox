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
        return matchWithIndices(query: query, candidate: candidate).score
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
        
        var queryIdx = 0
        var candidateIdx = 0
        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryCount)
        
        // ASCII lowercase: a-z = 97-122, A-Z = 65-90
        // To lowercase: if 65 <= c <= 90, add 32
        @inline(__always)
        func toLower(_ c: UInt8) -> UInt8 {
            return (c >= 65 && c <= 90) ? c + 32 : c
        }
        
        while queryIdx < queryCount && candidateIdx < candidateCount {
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
                    if prevChar == 32 || prevChar == 45 || prevChar == 95 {  // ' ', '-', '_'
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
           queryBytes.prefix(cachedQuery.count).elementsEqual(cachedQuery) {
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
        cachedCandidates = results.map { $0.application }

        return results
    }
}
