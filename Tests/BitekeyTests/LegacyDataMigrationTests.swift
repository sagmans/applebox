@testable import Bitekey
import XCTest

@MainActor
final class LegacyDataMigrationTests: XCTestCase {
    private enum Fixture {
        static let appSupportPath = "/Users/testuser/Library/Application Support"
        static let shortcutKey = "GlobalShortcut.application"
        static let pausedKey = "ClipboardCapturePaused"
        static let unrelatedKey = "Unrelated"
        static let markerKey = LegacyDataMigration.markerKey
        static let legacyShortcut = "legacy-shortcut"
        static let newShortcut = "new-shortcut"
        static let changedShortcut = "changed-shortcut"
        static let suitePrefix = "test."
        static let unrelatedValue = "unrelated-value"
    }

    private var fileSystem: MockFileSystem!
    private var preferences: UserDefaults!
    private var legacyPreferences: UserDefaults!
    private var suiteNames: [String] = []
    private let appSupport = URL(fileURLWithPath: Fixture.appSupportPath)

    private var legacyFolder: URL {
        appSupport.appendingPathComponent(LegacyDataMigration.legacyFolderName, isDirectory: true)
    }

    private var newFolder: URL {
        appSupport.appendingPathComponent(AppDataLocation.folderName, isDirectory: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        fileSystem = MockFileSystem()
        fileSystem.mockURLs = [appSupport]
        preferences = makeDefaults()
        legacyPreferences = makeDefaults()
    }

    override func tearDown() async throws {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        fileSystem = nil
        preferences = nil
        legacyPreferences = nil
        try await super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "\(Fixture.suitePrefix)\(UUID())"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func addLegacyFolder(kind: FileItemKind = .directory) {
        fileSystem.addFile(at: legacyFolder.path, isDirectory: true)
        fileSystem.itemKinds[legacyFolder.path] = kind
    }

    private func makeMigration() -> LegacyDataMigration {
        LegacyDataMigration(fileSystem: fileSystem, preferences: preferences, legacyPreferences: legacyPreferences)
    }

    func testCopiesLegacyFolderWhenNewMissing() {
        addLegacyFolder()

        let report = makeMigration().run()

        XCTAssertEqual(report.folder, .done)
        XCTAssertEqual(fileSystem.copyItemCalls.count, 1)
        XCTAssertEqual(fileSystem.copyItemCalls.first?.source, legacyFolder)
        XCTAssertTrue(fileSystem.copyItemCalls.first?.destination.lastPathComponent.hasPrefix(LegacyDataMigration.tempPrefix) == true)
        XCTAssertEqual(fileSystem.moveItemCalls.count, 1)
        XCTAssertEqual(fileSystem.moveItemCalls.first?.destination, newFolder)
    }

    func testReportsFailureWhenNewExistsAndLegacyReal() {
        addLegacyFolder()
        fileSystem.addFile(at: newFolder.path, isDirectory: true)

        let report = makeMigration().run()

        guard case .failed = report.folder else { return XCTFail("expected failed, got \(report.folder)") }
        XCTAssertEqual(fileSystem.copyItemCalls.count, 0)
        XCTAssertFalse(preferences.bool(forKey: LegacyDataMigration.folderMarkerKey))
    }

    func testSkipsWhenNoLegacyFolderAndSetsMarker() {
        XCTAssertEqual(makeMigration().run().folder, .skipped)
        XCTAssertEqual(fileSystem.copyItemCalls.count, 0)
        XCTAssertTrue(preferences.bool(forKey: LegacyDataMigration.folderMarkerKey))
    }

    func testLegacyFolderThatIsSymlinkFailsWithoutMarker() {
        addLegacyFolder(kind: .symbolicLink)

        guard case .failed = makeMigration().run().folder else { return XCTFail("expected failed") }
        XCTAssertEqual(fileSystem.copyItemCalls.count, 0)
        XCTAssertFalse(preferences.bool(forKey: LegacyDataMigration.folderMarkerKey))
    }

    func testItemKindErrorFailsWithoutMarker() {
        fileSystem.itemKindError = CocoaError(.fileReadNoPermission)

        guard case .failed = makeMigration().run().folder else { return XCTFail("expected failed") }
        XCTAssertEqual(fileSystem.copyItemCalls.count, 0)
        XCTAssertFalse(preferences.bool(forKey: LegacyDataMigration.folderMarkerKey))
    }

    func testCopyAndCleanupFailureReportBothCauses() {
        addLegacyFolder()
        fileSystem.copyItemError = CocoaError(.fileWriteOutOfSpace)
        fileSystem.removeItemError = CocoaError(.fileWriteNoPermission)

        guard case let .failed(failure) = makeMigration().run().folder else { return XCTFail("expected failed") }
        XCTAssertTrue(failure.detail.contains("Code=\(CocoaError.fileWriteOutOfSpace.rawValue)"))
        XCTAssertTrue(failure.detail.contains("Code=\(CocoaError.fileWriteNoPermission.rawValue)"))
    }

    func testRemovesStaleTempBeforeCopy() {
        addLegacyFolder()
        let stale = appSupport.appendingPathComponent("\(LegacyDataMigration.tempPrefix)stale", isDirectory: true)
        let other = appSupport.appendingPathComponent("Other", isDirectory: true)
        fileSystem.addFile(at: stale.path, isDirectory: true)
        fileSystem.directoryContents[appSupport] = [stale, other, legacyFolder]

        _ = makeMigration().run()

        XCTAssertEqual(fileSystem.removeItemCalls, [stale])
        XCTAssertEqual(fileSystem.existingFiles[stale.path], nil)
    }

    func testCopyFailureRemovesTempAndReportsFailed() {
        addLegacyFolder()
        fileSystem.copyItemError = CocoaError(.fileWriteOutOfSpace)

        let report = makeMigration().run()

        guard case .failed = report.folder else { return XCTFail("expected failed, got \(report.folder)") }
        let copyTarget = fileSystem.copyItemCalls.first?.destination
        XCTAssertNotNil(copyTarget)
        XCTAssertTrue(fileSystem.removeItemCalls.contains { $0 == copyTarget })
        XCTAssertNil(fileSystem.existingFiles[newFolder.path])
    }

    func testCopiesOnlyAllowlistedPreferences() {
        legacyPreferences.set(Fixture.legacyShortcut, forKey: Fixture.shortcutKey)
        legacyPreferences.set(true, forKey: Fixture.pausedKey)
        legacyPreferences.set(Fixture.unrelatedValue, forKey: Fixture.unrelatedKey)

        let report = makeMigration().run()

        XCTAssertEqual(report.preferences, .done)
        XCTAssertEqual(preferences.string(forKey: Fixture.shortcutKey), Fixture.legacyShortcut)
        XCTAssertEqual(preferences.object(forKey: Fixture.pausedKey) as? Bool, true)
        XCTAssertNil(preferences.object(forKey: Fixture.unrelatedKey))
    }

    func testKeepsExistingNewPreferenceValues() {
        legacyPreferences.set(Fixture.legacyShortcut, forKey: Fixture.shortcutKey)
        preferences.set(Fixture.newShortcut, forKey: Fixture.shortcutKey)

        _ = makeMigration().run()

        XCTAssertEqual(preferences.string(forKey: Fixture.shortcutKey), Fixture.newShortcut)
    }

    func testMarkerPreventsSecondCopy() {
        legacyPreferences.set(Fixture.legacyShortcut, forKey: Fixture.shortcutKey)
        _ = makeMigration().run()
        legacyPreferences.set(Fixture.changedShortcut, forKey: Fixture.shortcutKey)
        preferences.removeObject(forKey: Fixture.shortcutKey)

        let second = makeMigration().run()

        XCTAssertEqual(second.preferences, .skipped)
        XCTAssertNil(preferences.object(forKey: Fixture.shortcutKey))
    }

    func testMarksDoneWhenLegacyPreferencesEmpty() {
        _ = makeMigration().run()

        XCTAssertTrue(preferences.bool(forKey: Fixture.markerKey))
    }

    func testNeverWritesLegacyData() {
        addLegacyFolder()
        legacyPreferences.set(Fixture.legacyShortcut, forKey: Fixture.shortcutKey)

        _ = makeMigration().run()

        XCTAssertFalse(fileSystem.moveItemCalls.contains { $0.source == legacyFolder || $0.destination == legacyFolder })
        XCTAssertFalse(fileSystem.removeItemCalls.contains(legacyFolder))
        XCTAssertEqual(legacyPreferences.string(forKey: Fixture.shortcutKey), Fixture.legacyShortcut)
        XCTAssertNil(legacyPreferences.object(forKey: Fixture.markerKey))
    }

    func testFailedCopyThenStoreCreatedFolderStillReportsFailedAndNoMarker() {
        addLegacyFolder()
        fileSystem.copyItemError = CocoaError(.fileWriteOutOfSpace)
        _ = makeMigration().run()
        // A store creates the new folder after the failed launch step.
        fileSystem.addFile(at: newFolder.path, isDirectory: true)
        fileSystem.copyItemError = nil

        let second = makeMigration().run()

        guard case .failed = second.folder else { return XCTFail("expected failed, got \(second.folder)") }
        XCTAssertFalse(preferences.bool(forKey: LegacyDataMigration.folderMarkerKey))
    }

    func testSuccessSetsFolderMarkerAndMarkerSkipsCopy() {
        addLegacyFolder()
        XCTAssertEqual(makeMigration().run().folder, .done)
        XCTAssertTrue(preferences.bool(forKey: LegacyDataMigration.folderMarkerKey))
        fileSystem.copyItemCalls = []

        XCTAssertEqual(makeMigration().run().folder, .skipped)
        XCTAssertEqual(fileSystem.copyItemCalls.count, 0)
    }

    func testMoveFailureReportsFailedAndRemovesTemp() {
        addLegacyFolder()
        fileSystem.moveItemError = CocoaError(.fileWriteNoPermission)

        let report = makeMigration().run()

        guard case .failed = report.folder else { return XCTFail("expected failed, got \(report.folder)") }
        XCTAssertTrue(fileSystem.removeItemCalls.contains { $0.lastPathComponent.hasPrefix(LegacyDataMigration.tempPrefix) })
        XCTAssertNil(fileSystem.existingFiles[newFolder.path])
    }

    func testCopyThatIsNotDirectoryIsRemovedAndFails() {
        // The wrapper reports the copy as a non-directory, standing in for a copy that yielded a file or link.
        addLegacyFolder()
        let migration = LegacyDataMigration(fileSystem: NonDirectoryCopyFileSystem(base: fileSystem), preferences: preferences, legacyPreferences: legacyPreferences)

        guard case .failed = migration.run().folder else { return XCTFail("expected failed") }
        XCTAssertEqual(fileSystem.moveItemCalls.count, 0)
        XCTAssertTrue(fileSystem.removeItemCalls.contains { $0.lastPathComponent.hasPrefix(LegacyDataMigration.tempPrefix) })
    }

    func testSweepRunsWhenFolderMarkerSet() {
        preferences.set(true, forKey: LegacyDataMigration.folderMarkerKey)
        let stale = appSupport.appendingPathComponent("\(LegacyDataMigration.tempPrefix)stale", isDirectory: true)
        fileSystem.directoryContents[appSupport] = [stale]

        let report = makeMigration().run()

        XCTAssertEqual(report.staleTemps, .done)
        XCTAssertEqual(fileSystem.removeItemCalls, [stale])
    }

    func testSweepRemoveFailureReportsStaleTempsFailedButFolderMigrates() {
        addLegacyFolder()
        let stale = appSupport.appendingPathComponent("\(LegacyDataMigration.tempPrefix)stale", isDirectory: true)
        fileSystem.directoryContents[appSupport] = [stale]
        // Only the sweep removal fails; the folder step succeeds and never removes anything.
        fileSystem.removeItemError = CocoaError(.fileWriteNoPermission)

        let report = makeMigration().run()

        guard case .failed = report.staleTemps else { return XCTFail("expected failed, got \(report.staleTemps)") }
        XCTAssertEqual(report.folder, .done)
    }

    func testSweepListingFailureReportsStaleTempsFailed() {
        fileSystem.contentsOfDirectoryError = CocoaError(.fileReadNoPermission)

        guard case .failed = makeMigration().run().staleTemps else { return XCTFail("expected failed") }
    }

    func testNilLegacyPreferencesLeavesMarkerUnset() {
        let migration = LegacyDataMigration(fileSystem: fileSystem, preferences: preferences, legacyPreferences: nil)

        XCTAssertEqual(migration.run().preferences, .skipped)
        XCTAssertFalse(preferences.bool(forKey: Fixture.markerKey))
    }

    func testMarkerSetAfterSuccessfulPreferenceCopy() {
        legacyPreferences.set(Fixture.legacyShortcut, forKey: Fixture.shortcutKey)

        XCTAssertEqual(makeMigration().run().preferences, .done)
        XCTAssertTrue(preferences.bool(forKey: Fixture.markerKey))
    }

    func testFolderFailureDoesNotBlockPreferences() {
        addLegacyFolder()
        fileSystem.copyItemError = CocoaError(.fileWriteOutOfSpace)
        legacyPreferences.set(Fixture.legacyShortcut, forKey: Fixture.shortcutKey)

        let report = makeMigration().run()

        guard case .failed = report.folder else { return XCTFail("expected failed") }
        XCTAssertEqual(report.preferences, .done)
        XCTAssertEqual(preferences.string(forKey: Fixture.shortcutKey), Fixture.legacyShortcut)
    }
}

/// Wraps the mock so a copy leaves the temp path present but not a real directory, which is how a
/// copy that produced a file or link would look to the post-copy check.
private final nonisolated class NonDirectoryCopyFileSystem: FileSystemProtocol, @unchecked Sendable {
    private let base: MockFileSystem

    init(base: MockFileSystem) {
        self.base = base
    }

    var homeDirectoryForCurrentUser: URL {
        base.homeDirectoryForCurrentUser
    }

    func displayName(atPath path: String) -> String {
        base.displayName(atPath: path)
    }

    func urls(for directory: FileManager.SearchPathDirectory, in mask: FileManager.SearchPathDomainMask) -> [URL] {
        base.urls(for: directory, in: mask)
    }

    func fileExists(atPath path: String) -> Bool {
        base.fileExists(atPath: path)
    }

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        base.fileExists(atPath: path, isDirectory: isDirectory)
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, limit: Int) throws -> [URL] {
        try base.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask, limit: limit)
    }

    func isApplicationSearchFolder(at url: URL) -> Bool {
        base.isApplicationSearchFolder(at: url)
    }

    func isApplicationBundle(at url: URL) -> Bool {
        base.isApplicationBundle(at: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    func contents(atPath path: String) -> Data? {
        base.contents(atPath: path)
    }

    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool {
        base.createFile(atPath: path, contents: data, attributes: attr)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try base.write(data, to: url, options: options)
    }

    func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data? {
        try base.readPrivateFile(at: url, maximumBytes: maximumBytes)
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        try base.writePrivateFile(data, to: url)
    }

    func removePrivateFile(at url: URL) throws {
        try base.removePrivateFile(at: url)
    }

    func itemKind(at url: URL) throws -> FileItemKind {
        try base.itemKind(at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
        base.itemKinds[destination.path] = .other
    }
}
