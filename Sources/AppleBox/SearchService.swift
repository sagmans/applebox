import AppKit

enum FuzzyMatcher {
    /// fzf-style fuzzy matching score.
    /// Returns `0` if `query` is not a subsequence of `candidate`.
    static func score(query: String, candidate: String) -> Int {
        let normalizedQuery = query.lowercased()
        let normalizedCandidate = candidate.lowercased()

        guard !normalizedQuery.isEmpty else { return 0 }

        var queryIndex = normalizedQuery.startIndex
        var candidateIndex = normalizedCandidate.startIndex
        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false

        while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
            let queryChar = normalizedQuery[queryIndex]
            let candidateChar = normalizedCandidate[candidateIndex]

            if queryChar == candidateChar {
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

        return queryIndex < normalizedQuery.endIndex ? 0 : score
    }
}

// Represents a search result with a relevance score
struct SearchResult {
    let application: ApplicationInfo
    let score: Int
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
            let score = FuzzyMatcher.score(query: query, candidate: app.name)

            if score > 0 {
                results.append(SearchResult(application: app, score: score))
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
