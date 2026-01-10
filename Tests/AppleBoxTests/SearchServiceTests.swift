import XCTest
@testable import AppleBox

final class SearchServiceTests: XCTestCase {
    private var mockFileSystem: MockFileSystem!
    private var indexer: ApplicationIndexer!
    private var searchService: SearchService!
    
    override func setUp() {
        super.setUp()
        mockFileSystem = MockFileSystem()
        // Set up a mock file system with test applications
        setupMockApplications()
        indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        searchService = SearchService(indexer: indexer)
    }
    
    override func tearDown() {
        mockFileSystem = nil
        indexer = nil
        searchService = nil
        super.tearDown()
    }
    
    /// Sets up a mock file system with various test applications
    private func setupMockApplications() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        
        // Create URLs for test applications
        let safari = appsDir.appendingPathComponent("Safari.app")
        let safariTechnology = appsDir.appendingPathComponent("Safari Technology Preview.app")
        let mail = appsDir.appendingPathComponent("Mail.app")
        let music = appsDir.appendingPathComponent("Music.app")
        let photoShop = appsDir.appendingPathComponent("Photo Shop.app") // Fake app for testing word boundary
        let xcode = appsDir.appendingPathComponent("Xcode.app")
        let finder = appsDir.appendingPathComponent("Finder.app")
        let terminal = appsDir.appendingPathComponent("Terminal.app")
        let textEdit = appsDir.appendingPathComponent("TextEdit.app")
        let appStore = appsDir.appendingPathComponent("App Store.app")
        
        let allApps = [safari, safariTechnology, mail, music, photoShop, xcode, finder, terminal, textEdit, appStore]
        
        // Mark /Applications as existing directory
        mockFileSystem.addDirectory(at: appsDir, contents: allApps)
        
        // Mark System Applications as non-existent (skip)
        mockFileSystem.existingFiles["/System/Applications"] = false
        
        // Mark user Applications as non-existent (skip)
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Mark each app bundle as existing directory
        for app in allApps {
            mockFileSystem.existingFiles[app.path] = true
            mockFileSystem.directoryFlags[app.path] = true
        }
    }
    
    // MARK: - Test Exact Match Scores Highest
    
    func testExactMatchScoresHighest() {
        let results = searchService.search("Safari")
        
        XCTAssertFalse(results.isEmpty, "Should find results for 'Safari'")
        XCTAssertEqual(results.first?.application.name, "Safari", "Exact match should be first")
        
        // Safari should score >= Safari Technology Preview (both match "Safari" prefix equally)
        // Since scores are equal, alphabetical ordering puts "Safari" before "Safari Technology Preview"
        if results.count >= 2 {
            let safariResult = results.first { $0.application.name == "Safari" }
            let safariTechResult = results.first { $0.application.name == "Safari Technology Preview" }
            
            if let safari = safariResult, let safariTech = safariTechResult {
                XCTAssertGreaterThanOrEqual(safari.score, safariTech.score, 
                    "Exact match 'Safari' should score >= 'Safari Technology Preview'")
            }
        }
        
        // Verify Safari comes first (either higher score or alphabetical tiebreaker)
        let firstResult = results.first
        XCTAssertEqual(firstResult?.application.name, "Safari", 
            "Safari should appear before Safari Technology Preview")
    }
    
    // MARK: - Test Prefix Match Scores Higher Than Substring
    
    func testPrefixMatchScoresHigherThanSubstring() {
        // 'Saf' should match Safari with prefix bonus
        let results = searchService.search("Saf")
        
        XCTAssertFalse(results.isEmpty, "Should find results for 'Saf'")
        
        // Safari should be the first result due to prefix match
        XCTAssertEqual(results.first?.application.name, "Safari", 
            "Prefix match should prioritize Safari")
    }
    
    // MARK: - Test Consecutive Character Bonus
    
    func testConsecutiveCharacterBonus() {
        // Consecutive matches get bonus points
        // 'saf' should have higher consecutive bonus than 's' alone
        
        let safResults = searchService.search("saf")
        let sResults = searchService.search("s")
        
        let safariFromSaf = safResults.first { $0.application.name == "Safari" }
        let safariFromS = sResults.first { $0.application.name == "Safari" }
        
        XCTAssertNotNil(safariFromSaf, "'saf' should match Safari")
        XCTAssertNotNil(safariFromS, "'s' should match Safari")
        
        // 'saf' has consecutive matches which add bonus, so per-character it scores higher
        // Compare score per character - saf matches 3 chars with consecutive bonus
        if let saf = safariFromSaf, let s = safariFromS {
            // saf gets: 10 (s) + 20 (start bonus) + 10 (a) + 5*1 (consecutive) + 10 (f) + 5*2 (consecutive)
            // = 30 + 15 + 20 = 65
            // s gets: 10 (s) + 20 (start bonus) = 30
            XCTAssertGreaterThan(saf.score, s.score,
                "Consecutive 'saf' should score higher than single 's'")
        }
    }
    
    func testConsecutiveMatchesBeatNonConsecutive() {
        // Test consecutive vs non-consecutive matching on same-length queries
        // 'mai' (consecutive in Mail) vs 'mil' (non-consecutive in Mail)
        
        let consecutiveResults = searchService.search("mai")
        let nonConsecutiveResults = searchService.search("mil")
        
        let mailFromMai = consecutiveResults.first { $0.application.name == "Mail" }
        let mailFromMil = nonConsecutiveResults.first { $0.application.name == "Mail" }
        
        XCTAssertNotNil(mailFromMai, "'mai' should match Mail")
        XCTAssertNotNil(mailFromMil, "'mil' should match Mail")
        
        if let mai = mailFromMai, let mil = mailFromMil {
            // 'mai' is fully consecutive (m-a-i), 'mil' skips 'a' making it non-consecutive
            XCTAssertGreaterThan(mai.score, mil.score,
                "Consecutive 'mai' should score higher than non-consecutive 'mil'")
        }
    }
    
    // MARK: - Test Word Boundary Bonus
    
    func testWordBoundaryBonus() {
        // 'PS' should match 'Photo Shop' well due to word boundary matching
        let results = searchService.search("PS")
        
        let photoShop = results.first { $0.application.name == "Photo Shop" }
        XCTAssertNotNil(photoShop, "'PS' should match 'Photo Shop' via word boundaries")
        
        // It should have a decent score from the word boundary bonuses
        if let ps = photoShop {
            // P matches at start, S matches after space - both get bonuses
            XCTAssertGreaterThan(ps.score, 0, "'PS' matching 'Photo Shop' should have positive score")
        }
    }
    
    // MARK: - Test Case Insensitivity
    
    func testCaseInsensitivity() {
        let uppercaseResults = searchService.search("SAFARI")
        let lowercaseResults = searchService.search("safari")
        let mixedCaseResults = searchService.search("SaFaRi")
        
        XCTAssertFalse(uppercaseResults.isEmpty, "Uppercase 'SAFARI' should find results")
        XCTAssertFalse(lowercaseResults.isEmpty, "Lowercase 'safari' should find results")
        XCTAssertFalse(mixedCaseResults.isEmpty, "Mixed case 'SaFaRi' should find results")
        
        // All should return Safari as the first result
        XCTAssertEqual(uppercaseResults.first?.application.name, "Safari")
        XCTAssertEqual(lowercaseResults.first?.application.name, "Safari")
        XCTAssertEqual(mixedCaseResults.first?.application.name, "Safari")
        
        // All should have the same score
        XCTAssertEqual(uppercaseResults.first?.score, lowercaseResults.first?.score,
            "Case should not affect score")
        XCTAssertEqual(lowercaseResults.first?.score, mixedCaseResults.first?.score,
            "Case should not affect score")
    }
    
    // MARK: - Test No Match Returns Empty Results
    
    func testNoMatchReturnsEmptyResults() {
        let results = searchService.search("xyz")
        
        XCTAssertTrue(results.isEmpty, "Query 'xyz' should return no results")
    }
    
    func testNoMatchWithLongQuery() {
        let results = searchService.search("nonexistentapplication")
        
        XCTAssertTrue(results.isEmpty, "Query 'nonexistentapplication' should return no results")
    }
    
    // MARK: - Test Empty Query Returns Empty Results
    
    func testEmptyQueryReturnsEmptyResults() {
        let results = searchService.search("")
        
        XCTAssertTrue(results.isEmpty, "Empty query should return empty results")
    }
    
    // MARK: - Test Result Ordering
    
    func testResultOrderingByScore() {
        // Test that results are sorted by score (highest first)
        let results = searchService.search("a")
        
        // Multiple apps contain 'a' - verify they're sorted by score
        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(results[i].score, results[i + 1].score,
                "Results should be sorted by score in descending order")
        }
    }
    
    func testResultOrderingAlphabeticalTiebreaker() {
        // When scores are equal, results should be sorted alphabetically
        // Using 'x' which only matches Xcode
        let results = searchService.search("x")
        
        XCTAssertFalse(results.isEmpty, "Should find Xcode")
        XCTAssertEqual(results.first?.application.name, "Xcode")
    }
    
    func testAlphabeticalTiebreakerForSameScore() {
        // Find two apps that might have similar scores and verify alphabetical ordering
        // 'e' appears in multiple app names
        let results = searchService.search("e")
        
        // Check that within same-score groups, names are alphabetically sorted
        var previousScore: Int?
        var previousName: String?
        
        for result in results {
            if let prevScore = previousScore, let prevName = previousName {
                if result.score == prevScore {
                    // Same score - should be alphabetically after previous
                    XCTAssertGreaterThanOrEqual(result.application.name, prevName,
                        "Same-score results should be alphabetically sorted")
                }
            }
            previousScore = result.score
            previousName = result.application.name
        }
    }
    
    // MARK: - Additional Edge Cases
    
    func testSingleCharacterQuery() {
        // Single character should still work
        let results = searchService.search("s")
        
        XCTAssertFalse(results.isEmpty, "Single character 's' should find results")
        // Safari and App Store both contain 's'
        let safariFound = results.contains { $0.application.name == "Safari" }
        XCTAssertTrue(safariFound, "Should find Safari with single character 's'")
    }
    
    func testWhitespaceInQuery() {
        // Query with spaces should work for apps with spaces in names
        let results = searchService.search("App Store")
        
        let appStoreFound = results.contains { $0.application.name == "App Store" }
        XCTAssertTrue(appStoreFound, "Should find 'App Store' with space in query")
    }
    
    func testPartialMatchAcrossWords() {
        // 'te' should match Terminal, TextEdit
        let results = searchService.search("te")
        
        XCTAssertFalse(results.isEmpty, "'te' should find results")
        
        let terminalFound = results.contains { $0.application.name == "Terminal" }
        let textEditFound = results.contains { $0.application.name == "TextEdit" }
        
        XCTAssertTrue(terminalFound, "'te' should match Terminal")
        XCTAssertTrue(textEditFound, "'te' should match TextEdit")
    }
    
    func testScoreOnlyPositiveMatches() {
        // Verify that all returned results have positive scores
        let results = searchService.search("m")
        
        for result in results {
            XCTAssertGreaterThan(result.score, 0, 
                "All returned results should have positive scores")
        }
    }
}
