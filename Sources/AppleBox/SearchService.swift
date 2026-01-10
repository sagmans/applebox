import AppKit

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

        let lowerQuery = query.lowercased()
        var results: [SearchResult] = []

        for app in indexer.allApplications {
            let score = fuzzyScore(query: lowerQuery, appName: app.name.lowercased())

            // Only include if there's a match (score > 0)
            if score > 0 {
                results.append(SearchResult(application: app, score: score))
            }
        }

        // Sort by score (highest first), then by name alphabetically
        return results.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.application.name < $1.application.name
        }
    }

    /// Calculate fuzzy matching score
    /// - Parameters:
    ///   - query: The search query (lowercased)
    ///   - appName: The application name (lowercased)
    /// - Returns: Relevance score (higher is better match)
    private func fuzzyScore(query: String, appName: String) -> Int {
        guard !query.isEmpty else { return 0 }

        var queryIndex = query.startIndex
        var appIndex = appName.startIndex
        var score = 0
        var consecutiveMatches = 0
        var previousCharWasMatch = false

        // Try to match each character in query
        while queryIndex < query.endIndex && appIndex < appName.endIndex {
            let queryChar = query[queryIndex]
            let appChar = appName[appIndex]

            if queryChar == appChar {
                // Found a match
                score += 10

                // Bonus for consecutive matches
                if previousCharWasMatch {
                    consecutiveMatches += 1
                    score += 5 * consecutiveMatches
                } else {
                    consecutiveMatches = 0
                }

                // Bonus for match at start of string
                if appIndex == appName.startIndex {
                    score += 20
                }

                // Bonus for match after a space or hyphen (word boundary)
                if appIndex > appName.startIndex {
                    let previousIndex = appName.index(before: appIndex)
                    let previousChar = appName[previousIndex]
                    if previousChar == " " || previousChar == "-" || previousChar == "_" {
                        score += 15
                    }
                }

                queryIndex = query.index(after: queryIndex)
                previousCharWasMatch = true
            } else {
                previousCharWasMatch = false
            }

            appIndex = appName.index(after: appIndex)
        }

        // If we didn't match all characters, it's not a valid match
        return queryIndex < query.endIndex ? 0 : score
    }
}
