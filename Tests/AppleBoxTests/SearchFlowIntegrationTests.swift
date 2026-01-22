@testable import AppleBox
import XCTest

/// Integration tests verifying SearchService works correctly with ApplicationIndexer
/// Tests the end-to-end flow: mock file system -> ApplicationIndexer -> SearchService -> results
final class SearchFlowIntegrationTests: XCTestCase {
    private var mockFileSystem: MockFileSystem!

    override func setUp() {
        super.setUp()
        mockFileSystem = MockFileSystem()
    }

    override func tearDown() {
        mockFileSystem = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Sets up a mock directory with the given app bundles
    private func setupDirectory(at url: URL, withApps appNames: [String]) {
        let appURLs = appNames.map { url.appendingPathComponent("\($0).app") }
        mockFileSystem.addDirectory(at: url, contents: appURLs)

        // Mark each app bundle as existing directory
        for appURL in appURLs {
            mockFileSystem.existingFiles[appURL.path] = true
            mockFileSystem.directoryFlags[appURL.path] = true
        }
    }

    /// Marks a directory as non-existent
    private func markDirectoryNonExistent(at url: URL) {
        mockFileSystem.existingFiles[url.path] = false
    }

    // MARK: - End-to-End Flow Tests

    func testEndToEndSearchFlow() {
        // Set up mock file system with applications
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail", "Music", "Finder"])

        // Mark other directories as non-existent
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        // Create indexer and search service (end-to-end flow)
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Perform search and verify results
        let results = searchService.search("Mail")

        XCTAssertFalse(results.isEmpty, "Should find Mail application")
        XCTAssertEqual(results.first?.application.name, "Mail", "Mail should be the first result")
    }

    func testEndToEndFlowWithMultipleDirectories() {
        // Set up multiple search directories
        let systemApps = URL(fileURLWithPath: "/System/Applications")
        let mainApps = URL(fileURLWithPath: "/Applications")
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)

        setupDirectory(at: systemApps, withApps: ["Calculator", "Notes"])
        setupDirectory(at: mainApps, withApps: ["Safari", "Xcode"])
        setupDirectory(at: userApps, withApps: ["CustomApp"])

        // Create indexer and search service
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Verify all directories are indexed
        XCTAssertEqual(indexer.allApplications.count, 5, "Should find 5 applications across all directories")

        // Search for app from each directory
        let calcResults = searchService.search("Calculator")
        let safariResults = searchService.search("Safari")
        let customResults = searchService.search("Custom")

        XCTAssertFalse(calcResults.isEmpty, "Should find Calculator from system apps")
        XCTAssertFalse(safariResults.isEmpty, "Should find Safari from main apps")
        XCTAssertFalse(customResults.isEmpty, "Should find CustomApp from user apps")
    }

    func testEndToEndFlowWithEmptyFileSystem() {
        // Mark all directories as non-existent
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/Applications"))
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        // Create indexer and search service
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Verify empty results
        XCTAssertTrue(indexer.allApplications.isEmpty, "Should have no applications indexed")

        let results = searchService.search("anything")
        XCTAssertTrue(results.isEmpty, "Search should return empty for non-existent apps")
    }

    // MARK: - Search Returns Correct Applications from Indexed Set

    func testSearchReturnsCorrectApplicationsFromIndexedSet() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Safari Technology Preview", "Mail", "Music"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Search for "Safari" - should return both Safari apps
        let results = searchService.search("Safari")

        XCTAssertEqual(results.count, 2, "Should find both Safari applications")

        let resultNames = results.map(\.application.name)
        XCTAssertTrue(resultNames.contains("Safari"), "Should include Safari")
        XCTAssertTrue(resultNames.contains("Safari Technology Preview"), "Should include Safari Technology Preview")
    }

    func testSearchOnlyReturnsMatchingApplications() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail", "Music", "Finder", "Notes"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Search for "M" - should return Mail and Music
        let results = searchService.search("M")

        XCTAssertEqual(results.count, 2, "Should find only Mail and Music")

        let resultNames = results.map(\.application.name)
        XCTAssertTrue(resultNames.contains("Mail"), "Should include Mail")
        XCTAssertTrue(resultNames.contains("Music"), "Should include Music")
        XCTAssertFalse(resultNames.contains("Safari"), "Should not include Safari")
        XCTAssertFalse(resultNames.contains("Finder"), "Should not include Finder")
    }

    func testSearchExcludesNonMatchingApplications() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Xcode", "TextEdit", "Terminal"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Search for exact match that only matches one app
        let results = searchService.search("Xcode")

        XCTAssertEqual(results.count, 1, "Should find only Xcode")
        XCTAssertEqual(results.first?.application.name, "Xcode")
    }

    // MARK: - Search Ranking Matches Expected Order

    func testSearchRankingExactMatchFirst() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Safari Technology Preview", "SuperSafari"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        let results = searchService.search("Safari")

        // "Safari" exact match should be first (alphabetically before "Safari Technology Preview")
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.application.name, "Safari", "Exact match should be first")
    }

    func testSearchRankingPrefixMatchBeforeSubstring() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        // "Terminal" starts with "Term", "FasterMinal" contains "term" as substring
        setupDirectory(at: appsDir, withApps: ["Terminal", "FasterMinal"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        let results = searchService.search("Term")

        // Terminal should rank higher due to prefix match bonus
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.application.name, "Terminal", "Prefix match should rank higher than substring")
    }

    func testSearchRankingHigherScoreFirst() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Mail", "Gmail", "Airmail"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        let results = searchService.search("mail")

        // Verify results are sorted by score (descending)
        for i in 0 ..< (results.count - 1) {
            XCTAssertGreaterThanOrEqual(results[i].score, results[i + 1].score,
                                        "Results should be sorted by score in descending order")
        }

        // Mail should be first due to prefix match at start of string
        XCTAssertEqual(results.first?.application.name, "Mail", "Mail should rank highest with start-of-string prefix")
    }

    func testSearchRankingAlphabeticalTiebreaker() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        // Apps that might have similar scores
        setupDirectory(at: appsDir, withApps: ["Notes", "News"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        let results = searchService.search("N")

        XCTAssertEqual(results.count, 2, "Should find both apps starting with N")

        // If scores are equal, alphabetical order applies
        if results.count == 2, results[0].score == results[1].score {
            XCTAssertLessThan(results[0].application.name, results[1].application.name,
                              "Same-score results should be alphabetically sorted")
        }
    }

    // MARK: - Rescan Updates Search Results

    func testRescanUpdatesSearchResults() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Initial search
        let initialResults = searchService.search("Music")
        XCTAssertTrue(initialResults.isEmpty, "Music should not exist initially")

        // Add new application
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail", "Music"])

        // Rescan
        indexer.scanForApplications()

        // Search again
        let updatedResults = searchService.search("Music")
        XCTAssertFalse(updatedResults.isEmpty, "Music should be found after rescan")
        XCTAssertEqual(updatedResults.first?.application.name, "Music")
    }

    func testRescanRemovesDeletedApplications() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail", "Music"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Initial search - Music exists
        let initialResults = searchService.search("Music")
        XCTAssertFalse(initialResults.isEmpty, "Music should exist initially")

        // Remove Music from the directory contents
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail"])
        // Also remove Music from file system
        let musicPath = appsDir.appendingPathComponent("Music.app").path
        mockFileSystem.existingFiles[musicPath] = false
        mockFileSystem.directoryFlags[musicPath] = false

        // Rescan
        indexer.scanForApplications()

        // Search again - Music should no longer exist
        let updatedResults = searchService.search("Music")
        XCTAssertTrue(updatedResults.isEmpty, "Music should not be found after deletion and rescan")
    }

    func testRescanReflectsChangesAcrossAllDirectories() {
        let systemApps = URL(fileURLWithPath: "/System/Applications")
        let mainApps = URL(fileURLWithPath: "/Applications")
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)

        // Initial setup
        setupDirectory(at: systemApps, withApps: ["Calculator"])
        setupDirectory(at: mainApps, withApps: ["Safari"])
        markDirectoryNonExistent(at: userApps)

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        XCTAssertEqual(indexer.allApplications.count, 2, "Should have 2 apps initially")

        // Add more apps to different directories
        setupDirectory(at: systemApps, withApps: ["Calculator", "Notes"])
        setupDirectory(at: mainApps, withApps: ["Safari", "Xcode"])
        setupDirectory(at: userApps, withApps: ["CustomApp"])

        // Rescan
        indexer.scanForApplications()

        // Verify all new apps are indexed
        XCTAssertEqual(indexer.allApplications.count, 5, "Should have 5 apps after rescan")

        // Verify search finds new apps
        let notesResults = searchService.search("Notes")
        let xcodeResults = searchService.search("Xcode")
        let customResults = searchService.search("Custom")

        XCTAssertFalse(notesResults.isEmpty, "Notes should be found after rescan")
        XCTAssertFalse(xcodeResults.isEmpty, "Xcode should be found after rescan")
        XCTAssertFalse(customResults.isEmpty, "CustomApp should be found after rescan")
    }

    func testRescanClearsOldApplicationsBeforeScanning() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["OldApp1", "OldApp2", "OldApp3"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)

        XCTAssertEqual(indexer.allApplications.count, 3, "Should have 3 apps initially")

        // Replace with completely different apps
        setupDirectory(at: appsDir, withApps: ["NewApp"])
        // Remove old apps from file system
        for oldApp in ["OldApp1", "OldApp2", "OldApp3"] {
            let path = appsDir.appendingPathComponent("\(oldApp).app").path
            mockFileSystem.existingFiles[path] = false
            mockFileSystem.directoryFlags[path] = false
        }

        // Rescan
        indexer.scanForApplications()

        // Should only have the new app
        XCTAssertEqual(indexer.allApplications.count, 1, "Should have only 1 app after rescan")
        XCTAssertEqual(indexer.allApplications.first?.name, "NewApp")
    }

    // MARK: - Integration with Complex Scenarios

    func testSearchFlowWithSpecialCharactersInAppName() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Photo-Editor", "Video_Studio", "Music Player Plus"])
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Search with word boundary matching
        let photoResults = searchService.search("PE")
        XCTAssertFalse(photoResults.isEmpty, "Should find Photo-Editor with PE query")

        let videoResults = searchService.search("VS")
        XCTAssertFalse(videoResults.isEmpty, "Should find Video_Studio with VS query")
    }

    func testSearchFlowWithManyApplications() {
        let appsDir = URL(fileURLWithPath: "/Applications")

        // Create a large set of applications
        var appNames: [String] = []
        for i in 1 ... 100 {
            appNames.append("TestApp\(i)")
        }
        appNames.append("Safari")
        appNames.append("Xcode")

        setupDirectory(at: appsDir, withApps: appNames)
        markDirectoryNonExistent(at: URL(fileURLWithPath: "/System/Applications"))
        markDirectoryNonExistent(at: mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true))

        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let searchService = SearchService(indexer: indexer)

        // Verify all apps indexed
        XCTAssertEqual(indexer.allApplications.count, 102, "Should have all 102 apps indexed")

        // Search should still work efficiently
        let safariResults = searchService.search("Safari")
        XCTAssertFalse(safariResults.isEmpty)
        XCTAssertEqual(safariResults.first?.application.name, "Safari")

        // Search that matches many apps
        let testResults = searchService.search("Test")
        XCTAssertEqual(testResults.count, 100, "Should find all 100 TestApp applications")
    }
}
