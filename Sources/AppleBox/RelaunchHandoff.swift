import Darwin
import OSLog

/// Hands control from a quitting AppleBox to the copy it started, so a relaunch never runs two
/// instances at once. Two instances would both claim the global shortcuts and both write the
/// clipboard history files, so the new copy holds its setup until the old process is gone.
enum RelaunchHandoff {
    /// How the wait for the previous instance ended.
    enum Outcome {
        /// No previous instance to wait for, or it has exited: this copy may start its services.
        case ready
        /// The previous instance is still running at the timeout: this copy must quit.
        case previousStillRunning
    }

    /// Launch argument that names the process the new instance must outlive. Only AppleBox passes it.
    static let argument = "--relaunch-after"
    /// Shared by the handoff and the menu action so one log filter shows the whole relaunch.
    static let logCategory = "relaunch"
    /// Short enough that the relaunch feels immediate, long enough to keep the wait idle.
    static let pollInterval = Duration.milliseconds(50)
    /// The old instance cannot cancel its termination, so only a hung exit reaches this bound; a large
    /// history flush finishes well inside it. Quitting then keeps one instance instead of two, and the
    /// user can open AppleBox again.
    static let timeout = Duration.seconds(30)
    /// PID 0 is the kernel and 1 is launchd; neither can be a previous AppleBox.
    private static let firstAppProcess: pid_t = 2

    private static let logger = Logger(subsystem: LogSubsystem.name, category: logCategory)

    /// The process ID from the launch arguments, or nil for an ordinary launch. Arguments are
    /// untrusted input, so anything but a plausible other process ID counts as an ordinary launch.
    static func previousProcess(in arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1),
              let pid = pid_t(arguments[index + 1]),
              pid >= firstAppProcess,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return pid
    }

    /// Waits for the previous instance named in `arguments` to exit. Called after launch finishes,
    /// because the old instance quits only when macOS reports this one as launched; waiting earlier
    /// would make each process wait on the other.
    ///
    /// A reused PID would keep the wait going to the timeout. Darwin hands out PIDs in rising order,
    /// so reuse within the timeout is not a practical risk.
    static func waitForPreviousInstance(arguments: [String]) async -> Outcome {
        guard let previous = previousProcess(in: arguments) else { return .ready }
        let started = ContinuousClock.now
        while isRunning(previous) {
            guard ContinuousClock.now - started < timeout else {
                logger.error("Relaunch handoff timed out: previous pid=\(previous, privacy: .public) still running after \(timeout, privacy: .public)")
                return .previousStillRunning
            }
            // Nothing cancels the launch task, so a sleep error cannot occur and needs no handling.
            try? await Task.sleep(for: pollInterval)
        }
        logger.info("Relaunch handoff complete: previous pid=\(previous, privacy: .public) exited")
        return .ready
    }

    /// Signal 0 checks for the process without touching it. EPERM still means it exists.
    private static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
