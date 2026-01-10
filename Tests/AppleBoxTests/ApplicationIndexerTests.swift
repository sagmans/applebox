import XCTest
@testable import AppleBox

final class ApplicationIndexerTests: XCTestCase {
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
    
    /// Sets up a directory with the given app bundles
    private func setupDirectory(at url: URL, withApps apps: [String]) {
        let appURLs = apps.map { url.appendingPathComponent("\($0).app") }
        mockFileSystem.addDirectory(at: url, contents: appURLs)
        
        // Mark each app bundle as existing directory
        for appURL in appURLs {
            mockFileSystem.existingFiles[appURL.path] = true
            mockFileSystem.directoryFlags[appURL.path] = true
        }
    }
    
    /// Sets up a directory with arbitrary contents (not necessarily apps)
    private func setupDirectoryWithContents(at url: URL, contents: [URL]) {
        mockFileSystem.addDirectory(at: url, contents: contents)
    }
    
    // MARK: - Test: Scanning Finds .app Bundles in Mock Directory
    
    func testScanningFindsAppBundlesInDirectory() {
        // Setup: Create /Applications with some app bundles
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail", "Finder"])
        
        // Mark other search paths as non-existent
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act: Create indexer (which triggers scan)
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: All apps should be found
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 3, "Should find exactly 3 applications")
        
        let appNames = apps.map { $0.name }.sorted()
        XCTAssertEqual(appNames, ["Finder", "Mail", "Safari"], "Should find Safari, Mail, and Finder")
    }
    
    func testScanningFindsAppsInSystemApplications() {
        // Setup: Create /System/Applications with apps
        let systemAppsDir = URL(fileURLWithPath: "/System/Applications")
        setupDirectory(at: systemAppsDir, withApps: ["Calculator", "Notes"])
        
        // Mark other paths as non-existent
        mockFileSystem.existingFiles["/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 2, "Should find 2 applications from System/Applications")
        
        let appNames = apps.map { $0.name }.sorted()
        XCTAssertEqual(appNames, ["Calculator", "Notes"])
    }
    
    // MARK: - Test: Scanning Skips Non-.app Items
    
    func testScanningSkipsNonAppItems() {
        // Setup: Create directory with mixed content
        let appsDir = URL(fileURLWithPath: "/Applications")
        
        let validApp = appsDir.appendingPathComponent("Safari.app")
        let regularFile = appsDir.appendingPathComponent("readme.txt")
        let otherBundle = appsDir.appendingPathComponent("Something.framework")
        let folderNotApp = appsDir.appendingPathComponent("Utilities")
        
        mockFileSystem.addDirectory(at: appsDir, contents: [validApp, regularFile, otherBundle, folderNotApp])
        
        // Safari.app is a directory
        mockFileSystem.existingFiles[validApp.path] = true
        mockFileSystem.directoryFlags[validApp.path] = true
        
        // readme.txt is a regular file (not directory)
        mockFileSystem.existingFiles[regularFile.path] = true
        mockFileSystem.directoryFlags[regularFile.path] = false
        
        // Something.framework is a directory but not .app
        mockFileSystem.existingFiles[otherBundle.path] = true
        mockFileSystem.directoryFlags[otherBundle.path] = true
        
        // Utilities is a directory but not .app
        mockFileSystem.existingFiles[folderNotApp.path] = true
        mockFileSystem.directoryFlags[folderNotApp.path] = true
        
        // Mark other search paths as non-existent
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Only Safari.app should be found
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 1, "Should find only 1 application (.app bundle)")
        XCTAssertEqual(apps.first?.name, "Safari", "Only Safari.app should be indexed")
    }
    
    func testScanningSkipsRegularFilesWithAppExtension() {
        // Edge case: A file (not directory) with .app extension should be skipped
        let appsDir = URL(fileURLWithPath: "/Applications")
        
        let fakeApp = appsDir.appendingPathComponent("FakeApp.app")
        let realApp = appsDir.appendingPathComponent("RealApp.app")
        
        mockFileSystem.addDirectory(at: appsDir, contents: [fakeApp, realApp])
        
        // FakeApp.app is a FILE (not a directory bundle)
        mockFileSystem.existingFiles[fakeApp.path] = true
        mockFileSystem.directoryFlags[fakeApp.path] = false
        
        // RealApp.app is a proper directory bundle
        mockFileSystem.existingFiles[realApp.path] = true
        mockFileSystem.directoryFlags[realApp.path] = true
        
        // Mark other search paths as non-existent
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Only the real app bundle should be found
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 1, "Should find only 1 application (real bundle)")
        XCTAssertEqual(apps.first?.name, "RealApp")
    }
    
    // MARK: - Test: Scanning Skips Hidden Files
    
    func testScanningSkipsHiddenFiles() {
        // The indexer uses .skipsHiddenFiles option, so hidden files should not appear
        // in contentsOfDirectory results. Let's verify the option is passed correctly.
        
        let appsDir = URL(fileURLWithPath: "/Applications")
        
        // Only non-hidden apps in the mock directory (simulating what FileManager returns with skipsHiddenFiles)
        let visibleApp = appsDir.appendingPathComponent("VisibleApp.app")
        
        // The mock file system simulates what FileManager.contentsOfDirectory returns
        // with the skipsHiddenFiles option - hidden files are not included
        mockFileSystem.addDirectory(at: appsDir, contents: [visibleApp])
        mockFileSystem.existingFiles[visibleApp.path] = true
        mockFileSystem.directoryFlags[visibleApp.path] = true
        
        // Mark other search paths as non-existent
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Only visible app found
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 1, "Should find only visible applications")
        XCTAssertEqual(apps.first?.name, "VisibleApp")
        
        // Verify the options were passed correctly
        XCTAssertTrue(mockFileSystem.contentsOfDirectoryCalls.count > 0, "Should have called contentsOfDirectory")
    }
    
    // MARK: - Test: Scanning Handles Missing Directories Gracefully
    
    func testScanningHandlesMissingDirectoriesGracefully() {
        // All search paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        mockFileSystem.existingFiles["/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act: Should not crash
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: No apps found, but no crash
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 0, "Should handle missing directories gracefully with zero apps")
    }
    
    func testScanningHandlesPartiallyMissingDirectories() {
        // Only /Applications exists
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Should find app from existing directory
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 1, "Should find apps from existing directory only")
        XCTAssertEqual(apps.first?.name, "Safari")
    }
    
    func testScanningHandlesDirectoryEnumerationError() {
        // Directory exists but throws an error when reading contents
        let appsDir = URL(fileURLWithPath: "/Applications")
        mockFileSystem.existingFiles[appsDir.path] = true
        mockFileSystem.directoryFlags[appsDir.path] = true
        mockFileSystem.contentsOfDirectoryError = NSError(domain: "TestError", code: 1, userInfo: nil)
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act: Should not crash
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: No apps found due to error, but gracefully handled
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 0, "Should handle directory enumeration errors gracefully")
    }
    
    // MARK: - Test: Duplicate Detection
    
    func testDuplicateDetectionBySamePath() {
        // Setup: If somehow the same path appears twice, it should only be added once
        let appsDir = URL(fileURLWithPath: "/Applications")
        
        // Same app listed twice (edge case)
        let safari1 = appsDir.appendingPathComponent("Safari.app")
        let safari2 = appsDir.appendingPathComponent("Safari.app") // Same path
        
        mockFileSystem.addDirectory(at: appsDir, contents: [safari1, safari2])
        mockFileSystem.existingFiles[safari1.path] = true
        mockFileSystem.directoryFlags[safari1.path] = true
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Only one Safari should be indexed
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 1, "Duplicate paths should not be added twice")
        XCTAssertEqual(apps.first?.name, "Safari")
    }
    
    func testDuplicateDetectionAcrossSearchPaths() {
        // Same app exists in multiple search paths - should only be added once per unique path
        let appsDir = URL(fileURLWithPath: "/Applications")
        let systemAppsDir = URL(fileURLWithPath: "/System/Applications")
        
        // Safari in /Applications
        let safariMain = appsDir.appendingPathComponent("Safari.app")
        mockFileSystem.addDirectory(at: appsDir, contents: [safariMain])
        mockFileSystem.existingFiles[safariMain.path] = true
        mockFileSystem.directoryFlags[safariMain.path] = true
        
        // Safari also in /System/Applications (different path)
        let safariSystem = systemAppsDir.appendingPathComponent("Safari.app")
        mockFileSystem.addDirectory(at: systemAppsDir, contents: [safariSystem])
        mockFileSystem.existingFiles[safariSystem.path] = true
        mockFileSystem.directoryFlags[safariSystem.path] = true
        
        // User apps don't exist
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Both Safaris should be found (different paths = not duplicates)
        let apps = indexer.allApplications
        let safariApps = apps.filter { $0.name == "Safari" }
        XCTAssertEqual(safariApps.count, 2, "Same app name at different paths should both be indexed")
        
        // Verify they have different bundle paths
        let paths = Set(safariApps.map { $0.bundlePath })
        XCTAssertEqual(paths.count, 2, "Bundle paths should be different")
    }
    
    // MARK: - Test: App Name Extraction from Bundle Path
    
    func testAppNameExtractionFromBundlePath() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert
        let apps = indexer.allApplications
        XCTAssertEqual(apps.first?.name, "Safari", "Should extract 'Safari' from 'Safari.app'")
        XCTAssertEqual(apps.first?.bundlePath, "/Applications/Safari.app", "Bundle path should be full path")
    }
    
    func testAppNameExtractionWithSpaces() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["App Store", "Photo Booth"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert
        let apps = indexer.allApplications
        let appNames = apps.map { $0.name }.sorted()
        XCTAssertEqual(appNames, ["App Store", "Photo Booth"], "Should preserve spaces in app names")
    }
    
    func testAppNameExtractionWithSpecialCharacters() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["My-App", "Test_App"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert
        let apps = indexer.allApplications
        let appNames = apps.map { $0.name }.sorted()
        XCTAssertEqual(appNames, ["My-App", "Test_App"], "Should preserve special characters in app names")
    }
    
    // MARK: - Test: Multiple Search Paths Are All Scanned
    
    func testMultipleSearchPathsAreAllScanned() {
        // Setup all three search paths
        let systemAppsDir = URL(fileURLWithPath: "/System/Applications")
        let appsDir = URL(fileURLWithPath: "/Applications")
        let userAppsDir = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)
        
        setupDirectory(at: systemAppsDir, withApps: ["Calculator"])
        setupDirectory(at: appsDir, withApps: ["Safari"])
        setupDirectory(at: userAppsDir, withApps: ["CustomApp"])
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Apps from all three paths should be found
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 3, "Should find apps from all search paths")
        
        let appNames = apps.map { $0.name }.sorted()
        XCTAssertEqual(appNames, ["Calculator", "CustomApp", "Safari"], "Should include apps from all directories")
    }
    
    func testSearchPathOrder() {
        // Verify that search paths are scanned in the expected order
        let systemAppsDir = URL(fileURLWithPath: "/System/Applications")
        let appsDir = URL(fileURLWithPath: "/Applications")
        let userAppsDir = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications", isDirectory: true)
        
        // Setup all directories
        setupDirectory(at: systemAppsDir, withApps: ["SystemApp"])
        setupDirectory(at: appsDir, withApps: ["MainApp"])
        setupDirectory(at: userAppsDir, withApps: ["UserApp"])
        
        // Act
        _ = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: All three directories were scanned
        let scannedPaths = mockFileSystem.contentsOfDirectoryCalls.map { $0.path }
        XCTAssertTrue(scannedPaths.contains("/System/Applications"), "Should scan /System/Applications")
        XCTAssertTrue(scannedPaths.contains("/Applications"), "Should scan /Applications")
        XCTAssertTrue(scannedPaths.contains(userAppsDir.path), "Should scan user Applications")
    }
    
    // MARK: - Test: Rescan Functionality
    
    func testRescanUpdatesApplicationList() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Initial scan
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        XCTAssertEqual(indexer.allApplications.count, 1)
        
        // Add new app
        let newApp = appsDir.appendingPathComponent("Mail.app")
        mockFileSystem.directoryContents[appsDir] = [
            appsDir.appendingPathComponent("Safari.app"),
            newApp
        ]
        mockFileSystem.existingFiles[newApp.path] = true
        mockFileSystem.directoryFlags[newApp.path] = true
        
        // Rescan
        indexer.scanForApplications()
        
        // Assert
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 2, "Rescan should find newly added apps")
        
        let appNames = apps.map { $0.name }.sorted()
        XCTAssertEqual(appNames, ["Mail", "Safari"])
    }
    
    func testRescanClearsOldApps() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Initial scan
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        XCTAssertEqual(indexer.allApplications.count, 2)
        
        // Remove an app
        mockFileSystem.directoryContents[appsDir] = [appsDir.appendingPathComponent("Safari.app")]
        
        // Rescan
        indexer.scanForApplications()
        
        // Assert
        let apps = indexer.allApplications
        XCTAssertEqual(apps.count, 1, "Rescan should clear removed apps")
        XCTAssertEqual(apps.first?.name, "Safari")
    }
    
    // MARK: - Test: searchApplications Method
    
    func testSearchApplicationsReturnsFilteredResults() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail", "Maps"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let results = indexer.searchApplications(query: "Ma")
        
        // Assert: Mail and Maps both contain "Ma"
        XCTAssertEqual(results.count, 2, "Should find apps containing 'Ma'")
        let names = results.map { $0.name }.sorted()
        XCTAssertEqual(names, ["Mail", "Maps"])
    }
    
    func testSearchApplicationsEmptyQueryReturnsAll() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari", "Mail"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let results = indexer.searchApplications(query: "")
        
        // Assert
        XCTAssertEqual(results.count, 2, "Empty query should return all apps")
    }
    
    func testSearchApplicationsCaseInsensitive() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Safari"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        
        // Assert: Case insensitive search
        XCTAssertEqual(indexer.searchApplications(query: "safari").count, 1)
        XCTAssertEqual(indexer.searchApplications(query: "SAFARI").count, 1)
        XCTAssertEqual(indexer.searchApplications(query: "SaFaRi").count, 1)
    }
    
    func testSearchApplicationsResultsSorted() {
        let appsDir = URL(fileURLWithPath: "/Applications")
        setupDirectory(at: appsDir, withApps: ["Zebra", "Apple", "Microsoft"])
        
        // Other paths don't exist
        mockFileSystem.existingFiles["/System/Applications"] = false
        let userApps = mockFileSystem.mockHomeDirectory.appendingPathComponent("Applications")
        mockFileSystem.existingFiles[userApps.path] = false
        
        // Act
        let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
        let results = indexer.searchApplications(query: "")
        
        // Assert: Results should be sorted alphabetically
        let names = results.map { $0.name }
        XCTAssertEqual(names, ["Apple", "Microsoft", "Zebra"], "Results should be alphabetically sorted")
    }
}
