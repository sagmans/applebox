import AppKit

/// Result containing both score and matched character indices.
struct FuzzyMatchResult {
    let score: Int
    /// Character indices (0-based) in the candidate string that matched.
    let matchedIndices: [Int]
}

enum FuzzyMatcher {
    /// fzf-style fuzzy matching score.
    /// Returns `0` if `query` is not a subsequence of `candidate`.
    static func score(query: String, candidate: String) -> Int {
        return matchWithIndices(query: query, candidate: candidate).score
    }

    /// fzf-style fuzzy matching with score and match indices.
    /// Returns score `0` and empty indices if `query` is not a subsequence of `candidate`.
    static func matchWithIndices(query: String, candidate: String) -> FuzzyMatchResult {
        let normalizedQuery = query.lowercased()
        guard !normalizedQuery.isEmpty else { return FuzzyMatchResult(score: 0, matchedIndices: []) }
        return matchWithIndices(normalizedQuery: normalizedQuery, normalizedCandidate: candidate.lowercased())
    }

    /// Fast path for already-normalized inputs.
    /// - Note: `normalizedQuery` and `normalizedCandidate` must already be lowercased.
    static func matchWithIndices(normalizedQuery: String, normalizedCandidate: String) -> FuzzyMatchResult {
        guard !normalizedQuery.isEmpty else { return FuzzyMatchResult(score: 0, matchedIndices: []) }

        var queryIndex = normalizedQuery.startIndex
        var candidateIndex = normalizedCandidate.startIndex
        var candidateOffset = 0

        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(normalizedQuery.count)

        while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
            let queryChar = normalizedQuery[queryIndex]
            let candidateChar = normalizedCandidate[candidateIndex]

            if queryChar == candidateChar {
                matchedIndices.append(candidateOffset)

                score += 10

                if previousCharWasMatch {
                    consecutiveMatches += 1
                    score += 5 * consecutiveMatches
                } else {
                    consecutiveMatches = 0
                }

                if candidateIndex == normalizedCandidate.startIndex {
                    score += 20
                }

                if candidateIndex > normalizedCandidate.startIndex {
                    let previousIndex = normalizedCandidate.index(before: candidateIndex)
                    let previousChar = normalizedCandidate[previousIndex]
                    if previousChar == " " || previousChar == "-" || previousChar == "_" {
                        score += 15
                    }
                }

                queryIndex = normalizedQuery.index(after: queryIndex)
                previousCharWasMatch = true
            } else {
                previousCharWasMatch = false
            }

            candidateIndex = normalizedCandidate.index(after: candidateIndex)
            candidateOffset += 1
        }

        if queryIndex < normalizedQuery.endIndex {
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
    private var cachedQuery: String = ""
    private var cachedCandidates: [ApplicationInfo] = []

    init(indexer: ApplicationIndexer) {
        self.indexer = indexer
    }

    func allApplications() -> [ApplicationInfo] {
        indexer.allApplications
    }

    func resetCache() {
        cachedQuery = ""
        cachedCandidates = []
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

        let normalizedQuery = trimmedQuery.lowercased()
        let candidates: [ApplicationInfo]

        if !cachedQuery.isEmpty, !cachedCandidates.isEmpty, normalizedQuery.hasPrefix(cachedQuery) {
            candidates = cachedCandidates
        } else {
            candidates = indexer.allApplications
        }

        var results: [SearchResult] = []
        results.reserveCapacity(candidates.count)

        for app in candidates {
            if isCancelled() { return [] }

            let match = FuzzyMatcher.matchWithIndices(normalizedQuery: normalizedQuery, normalizedCandidate: app.normalizedName)

            if match.score > 0 {
                results.append(SearchResult(application: app, score: match.score, matchedIndices: match.matchedIndices))
            }
        }

        results.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.application.name < $1.application.name
        }

        if isCancelled() { return [] }

        cachedQuery = normalizedQuery
        cachedCandidates = results.map { $0.application }

        return results
    }
}
