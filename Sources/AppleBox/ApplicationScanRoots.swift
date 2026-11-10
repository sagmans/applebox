import CoreServices
import Foundation

/// What a folder refresh has to rescan. `.roots` holds root scan paths; an empty set means no
/// event could change the index.
nonisolated enum ApplicationRefreshScope: Sendable, Equatable {
    case roots(Set<String>)
    case all

    static let none = Self.roots([])

    var isEmpty: Bool {
        self == .none
    }

    /// Combine batches that arrive within one debounce window; any full rescan absorbs the rest.
    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case let (.roots(lhs), .roots(rhs)): .roots(lhs.union(rhs))
        default: .all
        }
    }

    func includes(_ scanPath: String) -> Bool {
        switch self {
        case let .roots(paths): paths.contains(scanPath)
        case .all: true
        }
    }
}

/// Decides which application folders a batch of filesystem events can affect, so the indexer
/// rescans one small root instead of every root when an app updater or build writes inside a bundle.
/// Symlinks in the root paths are resolved once at init; after that it never touches the
/// filesystem, so the indexer can call it from its scan queue.
nonisolated struct ApplicationScanRoots: Sendable {
    /// One watched folder. The scan path matches item URLs listed under the root, while the event
    /// path matches the canonical paths FSEvents reports even when the root sits behind a symlink.
    struct Root: Sendable {
        let url: URL
        let scanPath: String
        let eventPath: String
    }

    /// Places inside a bundle whose changes can flip whether it indexes or what it is called.
    /// Writes anywhere deeper, such as resources or frameworks, never change the index.
    private enum BundleLocation {
        case bundle
        case contents
        case infoPlist
        case executableDirectory
        case executable
        /// Deeper inside the bundle, where nothing changes the index.
        case other

        /// When FSEvents coalesces file events into a directory entry only the directory is
        /// known, so any change in a folder that holds an index-affecting item has to count.
        var holdsIndexAffectingItems: Bool {
            self == .bundle || self == .contents || self == .executableDirectory
        }
    }

    private static let contentsDirectoryName = "Contents"
    private static let infoPlistName = "Info.plist"
    private static let executableDirectoryName = "MacOS"
    private static let pathSeparator: Character = "/"
    private static let applicationExtension = "app"

    private static let itemTypeFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink
    )
    private static let directoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    /// Changes that can add, remove, rename or rewrite an item. Updaters that only clone or
    /// re-stamp a bundle report none of these.
    private static let itemChangeFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
    )
    /// Hidden flags, Finder visibility and permissions decide whether the scan lists a folder or
    /// bundle at all, and permissions decide whether the bundle executable is runnable.
    /// This means a permission or timestamp touch on a bundle folder still rescans its root; the
    /// hidden flag shares that event, so it cannot be told apart.
    /// Extended attributes are left out: launching an app stamps them on its bundle, and a rescan
    /// per launch would cost more than the rare Finder-only visibility change it would catch.
    private static let visibilityFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemFinderInfoMod
            | kFSEventStreamEventFlagItemChangeOwner
    )
    /// Event flags after which per-item paths no longer describe every change, so the only safe
    /// answer is to rescan everything.
    private static let rescanEverythingFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
    )
    /// Event flags that say a whole subtree changed, so bundle depth no longer filters anything.
    private static let wholeSubtreeFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
    )

    let roots: [Root]
    /// Paths of roots that also sit inside another root, in the form the parent's listing yields
    /// them; the parent scan skips them so each folder is listed once with its own entry budget.
    private let nestedRootPaths: Set<String>

    init(urls: [URL]) {
        roots = urls.map { url in
            Root(
                url: url,
                scanPath: url.standardizedFileURL.path,
                eventPath: url.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
        let scanPaths = roots.map(\.scanPath)
        nestedRootPaths = Set(scanPaths.filter { path in
            scanPaths.contains { other in other != path && Self.isPath(path, inside: other) }
        })
    }

    /// Tell the parent scan to leave a nested root to its own scan. Listed items carry their
    /// root's prefix, so a plain path lookup is enough in the scan's hot loop.
    func isNestedRoot(_ url: URL) -> Bool {
        nestedRootPaths.contains(url.path)
    }

    /// Unknown paths fall back to a full rescan, so a missed mapping can only cost time, never
    /// leave search stale.
    func refreshScope(for events: [ApplicationFolderMonitor.Event]) -> ApplicationRefreshScope {
        var affected = Set<String>()
        for event in events {
            if event.flags & Self.rescanEverythingFlags != 0 {
                return .all
            }
            let path = Self.trimmed(event.path)
            // A change in a folder that holds a nested root can create, remove or replace that root.
            let rootsBelow = roots.filter { Self.isPath($0.eventPath, inside: path) }.map(\.scanPath)
            guard let owner = owningRoot(of: path) else {
                // Outside every root only changes that can create or remove a root matter.
                guard !rootsBelow.isEmpty else { return .all }
                affected.formUnion(rootsBelow)
                continue
            }
            let relativeComponents = Self.components(of: path, below: owner.eventPath)
            guard event.flags & Self.wholeSubtreeFlags != 0 || Self.canAffectIndex(event.flags, relativeComponents: relativeComponents) else {
                continue
            }
            affected.insert(owner.scanPath)
            affected.formUnion(rootsBelow)
        }
        return .roots(affected)
    }

    /// Pick the deepest root so a change under a nested root rescans only that nested root.
    private func owningRoot(of path: String) -> Root? {
        roots
            .filter { $0.eventPath == path || Self.isPath(path, inside: $0.eventPath) }
            .max { $0.eventPath.count < $1.eventPath.count }
    }

    private static func canAffectIndex(_ flags: FSEventStreamEventFlags, relativeComponents: [String]) -> Bool {
        let bundleIndex = relativeComponents.firstIndex(where: isApplicationComponent)
        let location = bundleIndex.map { bundleLocation(of: Array(relativeComponents[($0 + 1)...])) }
        guard flags & itemTypeFlags != 0 else {
            // Coalesced directory entry: plain folders can gain or lose bundles directly.
            return location?.holdsIndexAffectingItems ?? true
        }
        let changed = flags & itemChangeFlags != 0
        let visibilityChanged = flags & visibilityFlags != 0
        guard let location else {
            // Outside bundles only folders matter: the scan never indexes loose files or follows
            // symlinked folders.
            return flags & directoryFlag != 0 && (changed || visibilityChanged)
        }
        switch location {
        case .bundle, .infoPlist, .executable:
            return changed || visibilityChanged
        case .contents, .executableDirectory:
            // Updaters re-stamp these folders constantly; only adding, removing or renaming
            // them changes the bundle check.
            return changed
        case .other:
            return false
        }
    }

    /// Match case-insensitively like the default APFS volume, which `Bundle` resolves through.
    private static func bundleLocation(of subpath: [String]) -> BundleLocation {
        func matches(_ component: String, _ name: String) -> Bool {
            component.caseInsensitiveCompare(name) == .orderedSame
        }
        guard let first = subpath.first else { return .bundle }
        guard matches(first, contentsDirectoryName) else { return .other }
        switch subpath.count {
        case 1:
            return .contents
        case 2 where matches(subpath[1], infoPlistName):
            return .infoPlist
        case 2 where matches(subpath[1], executableDirectoryName):
            return .executableDirectory
        case 3 where matches(subpath[1], executableDirectoryName):
            return .executable
        default:
            return .other
        }
    }

    private static func isApplicationComponent(_ component: String) -> Bool {
        (component as NSString).pathExtension.caseInsensitiveCompare(applicationExtension) == .orderedSame
    }

    private static func components(of path: String, below root: String) -> [String] {
        guard path != root else { return [] }
        return path.dropFirst(root.count).split(separator: pathSeparator).map(String.init)
    }

    /// FSEvents reports directories with a trailing separator; roots never have one.
    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.last == pathSeparator {
            path.removeLast()
        }
        return path
    }

    private static func isPath(_ path: String, inside ancestor: String) -> Bool {
        let prefix = ancestor.hasSuffix(String(pathSeparator)) ? ancestor : ancestor + String(pathSeparator)
        return path.hasPrefix(prefix)
    }
}
