import CoreServices
import Foundation

/// Let filesystem events drive index refreshes without repeatedly walking quiet folders.
/// Hands each batch's item paths and flags to the indexer, which rescans only the roots whose app
/// list can have changed.
/// Created from the indexer's nonisolated code and delivers events on the main queue, so it opts
/// out of default main-actor isolation. `@unchecked Sendable` is safe because `stream` is
/// immutable after init and FSEvents calls are thread-safe.
final nonisolated class ApplicationFolderMonitor: @unchecked Sendable {
    /// One FSEvents entry: the changed item, or a directory when FSEvents coalesces, and what changed.
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        /// Stands in for a batch that cannot be read, so the indexer rescans everything instead
        /// of missing a change.
        static let unreadableBatch = Event(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
    }

    private final class Callback: Sendable {
        let onChange: @Sendable ([Event]) -> Void

        init(onChange: @escaping @Sendable ([Event]) -> Void) {
            self.onChange = onChange
        }
    }

    private static let eventLatency: TimeInterval = 0.3
    /// File events name the changed item and say what changed, so the indexer can ignore updaters
    /// that only touch bundle metadata; directory events report those as folder content changes.
    /// CF types spare the callback manual C string decoding.
    private static let streamFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
    )
    private let stream: FSEventStreamRef

    init?(paths: [String], onChange: @escaping @Sendable ([Event]) -> Void) {
        let callback = Callback(onChange: onChange)
        // Let the stream own the callback for as long as native events can reach it.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Callback>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let createdStream = withExtendedLifetime(callback) {
            FSEventStreamCreate(
                nil,
                { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let events = ApplicationFolderMonitor.events(count: count, paths: paths, flags: flags)
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange(events)
                },
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.eventLatency,
                Self.streamFlags
            )
        }
        guard let stream = createdStream else { return nil }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    private static func events(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) -> [Event] {
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
        guard let strings = array as? [String], strings.count == count else {
            return [.unreadableBatch]
        }
        return strings.enumerated().map { index, path in Event(path: path, flags: flags[index]) }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
