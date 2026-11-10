import CoreServices
import Foundation

/// Let filesystem events drive index refreshes without repeatedly walking quiet folders.
/// Created from the indexer's nonisolated code and delivers events on the main queue, so it opts
/// out of default main-actor isolation. `@unchecked Sendable` is safe because `stream` is
/// immutable after init and FSEvents calls are thread-safe.
final nonisolated class ApplicationFolderMonitor: @unchecked Sendable {
    private final class Callback: Sendable {
        let onChange: @Sendable () -> Void

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    private static let eventLatency: TimeInterval = 0.3
    private let stream: FSEventStreamRef

    init?(paths: [String], onChange: @escaping @Sendable () -> Void) {
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
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange()
                },
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.eventLatency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
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

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
