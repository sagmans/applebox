@testable import AppleBox
import XCTest

/// Unit tests for FuzzyMatcher, focused on exact substring priority and index correctness.
@MainActor
final class FuzzyMatcherTests: XCTestCase {
    // MARK: - Exact Substring Priority Tests

    func testExactSubstringPreferredForBracketedQuery() throws {
        // Candidate has multiple '[' characters scattered, plus an exact "[main]" substring
        let candidate = "[13:52:52] [~/source/me/dotf][main] (~6, ?1)"
        let query = "[main]"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        // Should have matched
        XCTAssertGreaterThan(result.score, 0, "Should match")

        // Indices should be contiguous (exact substring)
        XCTAssertEqual(result.matchedIndices.count, query.count, "Should have \(query.count) matched indices")

        // Verify indices are contiguous
        for i in 1 ..< result.matchedIndices.count {
            XCTAssertEqual(
                result.matchedIndices[i],
                result.matchedIndices[i - 1] + 1,
                "Indices should be contiguous for exact substring match"
            )
        }

        // Verify the matched substring is actually "[main]"
        let startIdx = try XCTUnwrap(result.matchedIndices.first)
        let matchedSubstring = String(candidate.dropFirst(startIdx).prefix(query.count))
        XCTAssertEqual(matchedSubstring, "[main]", "Should match the exact '[main]' substring")
    }

    func testExactSubstringBeatsScatteredFuzzyMatch() {
        // Candidate A: contains exact "[main]"
        let candidateA = "build [main] passed"
        // Candidate B: only supports scattered subsequence match for "[main]"
        // Has [ m a i n ] scattered across the text
        let candidateB = "[log] message about interesting news]"

        let query = "[main]"

        let resultA = FuzzyMatcher.matchWithIndices(query: query, candidate: candidateA)
        let resultB = FuzzyMatcher.matchWithIndices(query: query, candidate: candidateB)

        // Both should match (B has [ m a i n ] scattered)
        XCTAssertGreaterThan(resultA.score, 0, "Candidate A should match")
        XCTAssertGreaterThan(resultB.score, 0, "Candidate B should match")

        // A (exact substring) should score higher than B (scattered)
        XCTAssertGreaterThan(
            resultA.score,
            resultB.score,
            "Exact substring match should score higher than scattered fuzzy match"
        )

        // A's indices should be contiguous
        for i in 1 ..< resultA.matchedIndices.count {
            XCTAssertEqual(
                resultA.matchedIndices[i],
                resultA.matchedIndices[i - 1] + 1,
                "Exact substring indices should be contiguous"
            )
        }
    }

    func testExactSubstringCaseInsensitive() {
        let candidate = "Release [MAIN] Branch"
        let query = "[main]"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0, "Should match case-insensitively")
        XCTAssertEqual(result.matchedIndices.count, query.count)

        // Verify indices are contiguous
        for i in 1 ..< result.matchedIndices.count {
            XCTAssertEqual(
                result.matchedIndices[i],
                result.matchedIndices[i - 1] + 1,
                "Indices should be contiguous"
            )
        }
    }

    func testEarliestSubstringOccurrenceChosen() throws {
        // Candidate has "[main]" appearing twice
        let candidate = "first [main] and second [main] here"
        let query = "[main]"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0, "Should match")

        // Should pick the first occurrence
        let startIdx = try XCTUnwrap(result.matchedIndices.first)
        let expectedStart = try XCTUnwrap(candidate.range(of: "[main]")?.lowerBound)
        let expectedStartInt = candidate.distance(from: candidate.startIndex, to: expectedStart)

        XCTAssertEqual(startIdx, expectedStartInt, "Should match the earliest occurrence")
    }

    func testFallbackToFuzzyWhenNoExactSubstring() {
        // Candidate does not contain exact "abc" but has a, b, c scattered
        let candidate = "alpha beta charlie"
        let query = "abc"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0, "Should match via fuzzy")
        XCTAssertEqual(result.matchedIndices.count, 3)

        // Indices should NOT be contiguous (fuzzy match)
        let isContiguous = (1 ..< result.matchedIndices.count).allSatisfy {
            result.matchedIndices[$0] == result.matchedIndices[$0 - 1] + 1
        }
        XCTAssertFalse(isContiguous, "Fuzzy match indices should not be contiguous")
    }

    func testNoMatchReturnsZeroScore() {
        let candidate = "hello world"
        let query = "xyz"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertEqual(result.score, 0, "Should return 0 for no match")
        XCTAssertTrue(result.matchedIndices.isEmpty, "Should have no matched indices")
    }

    // MARK: - Scoring Tests

    func testSubstringMatchHasHighBaseScore() {
        let candidate = "test [main] string"
        let query = "[main]"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        // Substring matches should have score >= 1_000_000
        XCTAssertGreaterThanOrEqual(result.score, 1_000_000, "Substring match should have high base score")
    }

    func testStartOfStringBonusApplied() {
        let candidateAtStart = "[main] at start"
        let candidateInMiddle = "in the [main] middle"
        let query = "[main]"

        let resultAtStart = FuzzyMatcher.matchWithIndices(query: query, candidate: candidateAtStart)
        let resultInMiddle = FuzzyMatcher.matchWithIndices(query: query, candidate: candidateInMiddle)

        XCTAssertGreaterThan(
            resultAtStart.score,
            resultInMiddle.score,
            "Match at start should score higher due to start bonus"
        )
    }

    func testWordBoundaryBonusApplied() {
        let candidateWithBoundary = "test [main] string" // space before [
        let candidateWithoutBoundary = "test[main]string" // no boundary
        let query = "[main]"

        let resultWithBoundary = FuzzyMatcher.matchWithIndices(query: query, candidate: candidateWithBoundary)
        let resultWithoutBoundary = FuzzyMatcher.matchWithIndices(query: query, candidate: candidateWithoutBoundary)

        XCTAssertGreaterThan(
            resultWithBoundary.score,
            resultWithoutBoundary.score,
            "Match after word boundary should score higher"
        )
    }

    // MARK: - Edge Cases

    func testEmptyQueryReturnsZero() {
        let candidate = "some text"
        let query = ""

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.matchedIndices.isEmpty)
    }

    func testEmptyCandidateReturnsZero() {
        let candidate = ""
        let query = "test"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.matchedIndices.isEmpty)
    }

    func testQueryLongerThanCandidateReturnsZero() {
        let candidate = "ab"
        let query = "abcdef"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.matchedIndices.isEmpty)
    }

    func testExactMatchOfEntireCandidate() {
        let candidate = "Safari"
        let query = "Safari"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0)
        XCTAssertEqual(result.matchedIndices, [0, 1, 2, 3, 4, 5])
    }

    func testSingleCharacterMatch() {
        let candidate = "Safari"
        let query = "a"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0)
        XCTAssertEqual(result.matchedIndices.count, 1)
        // Should match the first 'a' in Safari (index 1)
        XCTAssertEqual(result.matchedIndices.first, 1)
    }

    // MARK: - Real-World Scenarios

    func testTerminalPromptWithBranchName() throws {
        // Simulates the exact scenario from the bug report
        let candidate = "[13:52:52] [~/source/me/dotf][main] (~6, ?1)\n$ chmod +x benchmark.sh"
        let query = "[main]"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0)

        // Extract the matched substring
        let startIdx = try XCTUnwrap(result.matchedIndices.first)
        let endIdx = try XCTUnwrap(result.matchedIndices.last)
        let startStringIdx = candidate.index(candidate.startIndex, offsetBy: startIdx)
        let endStringIdx = candidate.index(candidate.startIndex, offsetBy: endIdx + 1)
        let matchedSubstring = String(candidate[startStringIdx ..< endStringIdx])

        XCTAssertEqual(matchedSubstring, "[main]", "Should highlight the branch name, not scattered characters")
    }

    func testGitBranchInPath() {
        let candidate = "~/projects/my-app (main) $ git status"
        let query = "main"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0)

        // Indices should be contiguous (exact substring "main")
        for i in 1 ..< result.matchedIndices.count {
            XCTAssertEqual(
                result.matchedIndices[i],
                result.matchedIndices[i - 1] + 1
            )
        }
    }

    func testCodeSnippetWithFunction() {
        let candidate = "func calculateTotal() -> Double"
        let query = "calc"

        let result = FuzzyMatcher.matchWithIndices(query: query, candidate: candidate)

        XCTAssertGreaterThan(result.score, 0)
        XCTAssertEqual(result.matchedIndices, [5, 6, 7, 8]) // "calc" in "calculateTotal"
    }

    // MARK: - Match runs (ported from WindowManagerTests highlight assertions)

    func testMatchRunsCoverExactSubstringAsSingleRun() throws {
        let content = "test [main] string"
        let result = FuzzyMatcher.matchWithIndices(query: "[main]", candidate: content)

        let runs = matchRuns(in: content, indices: result.matchedIndices)

        XCTAssertEqual(runs.count, 1, "Contiguous indices should form one run")
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(String(content[run.range]), "[main]")
    }

    func testMatchRunsPointAtFirstBranchOccurrence() throws {
        let content = "[13:52:52] [~/source/me/dotf][main] (~6, ?1)"
        let result = FuzzyMatcher.matchWithIndices(query: "[main]", candidate: content)

        let runs = matchRuns(in: content, indices: result.matchedIndices)

        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(String(content[run.range]), "[main]", "Highlighted indices should point to '[main]'")
    }
}
