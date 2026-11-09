import Foundation

/// Keep the work fixed so a slow machine or a loaded run does not change the sample size.
@main
enum SearchBenchmark {
    private static let candidateCount = 500
    private static let sampleCount = 7
    private static let queries = ["fixture", "utility", "fxt499", "no-result"]
    private static let medianLimit: Duration = .milliseconds(25)

    static func main() {
        let candidates = (0 ..< candidateCount).map { "Fixture Utility \($0)" }
        let clock = ContinuousClock()
        let expectedMatches = candidateCount * 2 + 1

        // Warm the same paths before measuring the median of full passes.
        guard runSearch(candidates) == expectedMatches else {
            fail("Unexpected search results")
        }

        let samples = (0 ..< sampleCount).map { _ in
            clock.measure {
                guard runSearch(candidates) == expectedMatches else {
                    fail("Unexpected search results")
                }
            }
        }.sorted()
        let median = samples[samples.count / 2]

        print("Search benchmark: median \(median), limit \(medianLimit), \(candidateCount) candidates per query")
        guard median <= medianLimit else {
            fail("Search benchmark exceeded its limit")
        }
    }

    private static func runSearch(_ candidates: [String]) -> Int {
        queries.reduce(0) { count, query in
            count + candidates.count { FuzzyMatcher.score(query: query, candidate: $0) > 0 }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
