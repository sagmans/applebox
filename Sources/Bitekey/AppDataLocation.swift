import Foundation

/// The one Application Support folder name for all persisted data, so the indexer, recents and
/// clipboard history cannot drift apart and a later rename touches a single place.
nonisolated enum AppDataLocation {
    static let folderName = "Bitekey"
}
