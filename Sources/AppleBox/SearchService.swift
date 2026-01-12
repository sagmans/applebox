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
        let normalizedCandidate = candidate.lowercased()

        guard !normalizedQuery.isEmpty else { return FuzzyMatchResult(score: 0, matchedIndices: []) }

        var queryIndex = normalizedQuery.startIndex
        var candidateIndex = normalizedCandidate.startIndex
        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false
        var matchedIndices: [Int] = []

        while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
            let queryChar = normalizedQuery[queryIndex]
            let candidateChar = normalizedCandidate[candidateIndex]

            if queryChar == candidateChar {
                let candidateOffset = normalizedCandidate.distance(from: normalizedCandidate.startIndex, to: candidateIndex)
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

class SearchService {
    private let indexer: ApplicationIndexer

    init(indexer: ApplicationIndexer) {
        self.indexer = indexer
    }

    /// Search applications using fuzzy matching
    /// - Parameter query: The search query
    /// - Returns: Sorted search results by relevance score (higher is better)
    func search(_ query: String) -> [SearchResult] {
        guard !query.isEmpty else {
            return []
        }

        var results: [SearchResult] = []

        for app in indexer.allApplications {
            let match = FuzzyMatcher.matchWithIndices(query: query, candidate: app.name)

            if match.score > 0 {
                results.append(SearchResult(application: app, score: match.score, matchedIndices: match.matchedIndices))
            }
        }

        return results.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.application.name < $1.application.name
        }
    }
}
