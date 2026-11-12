@testable import Bitekey
import XCTest

/// Runs the migration's file operations against a real folder, because the mock cannot show how
/// FileManager treats links and missing paths.
@MainActor
final class SystemFileManagerMigrationTests: XCTestCase {
    private enum Names {
        static let rootPrefix = "bitekey-fs-"
        static let directory = "dir"
        static let target = "target"
        static let link = "link"
        static let missing = "missing"
        static let file = "file"
        static let fileContents = "contents"
    }

    private var root: URL!
    private let fileSystem = SystemFileManager()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(Names.rootPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testItemKindDirectory() throws {
        XCTAssertEqual(try fileSystem.itemKind(at: makeDirectory(Names.directory)), .directory)
    }

    func testItemKindSymlinkToDirectoryIsSymbolicLink() throws {
        let target = try makeDirectory(Names.target)
        let link = root.appendingPathComponent(Names.link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(try fileSystem.itemKind(at: link), .symbolicLink)
    }

    func testItemKindMissing() throws {
        XCTAssertEqual(try fileSystem.itemKind(at: root.appendingPathComponent(Names.missing)), .missing)
    }

    func testItemKindRegularFileIsOther() throws {
        let file = root.appendingPathComponent(Names.file)
        try Data(Names.fileContents.utf8).write(to: file)

        XCTAssertEqual(try fileSystem.itemKind(at: file), .other)
    }

    func testRemoveItemOnMissingPathDoesNotThrow() {
        XCTAssertNoThrow(try fileSystem.removeItem(at: root.appendingPathComponent(Names.missing)))
    }

    func testRemoveItemOnSymlinkKeepsTarget() throws {
        let target = try makeDirectory(Names.target)
        let link = root.appendingPathComponent(Names.link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try fileSystem.removeItem(at: link)

        XCTAssertEqual(try fileSystem.itemKind(at: target), .directory)
        XCTAssertEqual(try fileSystem.itemKind(at: link), .missing)
    }
}
