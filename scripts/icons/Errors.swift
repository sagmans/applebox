// One error domain for the generator, so every failure reaches the single
// handler in `main.swift` with its operation, path and cause.

import Foundation

/// Each case carries the path, tool or arguments needed to diagnose it in one pass.
enum RenderFailure: LocalizedError {
    case invalidArguments([String])
    case writeFailed(path: String, cause: Error)
    case invalidOutput(path: String, reason: String)
    case repositoryRootNotFound(checked: String)
    case unreadableInput(path: String, reason: String)
    case renderFailed(path: String, reason: String)
    /// `pixel` is free-form detail (a pixel and its samples, the size, the
    /// format or the visible-pixel count): the task brief fixed this signature.
    case badTemplate(path: String, pixel: String)
    case toolMissing(tool: String, path: String)
    case toolLaunchFailed(tool: String, cause: Error)
    case toolFailed(tool: String, arguments: [String], status: Int32, elapsed: TimeInterval, stderr: String)
    case toolTimedOut(tool: String, arguments: [String], elapsed: TimeInterval)

    /// One sentence per case naming what failed and how to fix it, because `main` prints only this.
    var errorDescription: String? {
        switch self {
        case let .invalidArguments(arguments):
            "Expected one command (\(Command.allCases.map(\.rawValue).joined(separator: " | "))), got: \(arguments)."
        case let .writeFailed(path, cause):
            "Could not write \(path): \(cause.localizedDescription)"
        case let .invalidOutput(path, reason):
            "Generated \(path) failed its self-check: \(reason)"
        case let .repositoryRootNotFound(checked):
            "Refusing to write icons: could not confirm the repository root from \(checked). The generator must be compiled from the Bitekey repository's scripts/icons folder with absolute paths; run `make icons`."
        case let .unreadableInput(path, reason):
            "Could not read \(path): \(reason). Run `make icons`, which writes the sources first."
        case let .renderFailed(path, reason):
            "Could not render \(path): \(reason)"
        case let .badTemplate(path, pixel):
            "\(path) is not a valid menu-bar template image: \(pixel). Template images must be pure black with alpha, at \(MenuBitmap.pointSize) or \(MenuBitmap.pointSize * 2) px."
        case let .toolMissing(tool, path):
            "\(tool) was not found (\(path)). Install Xcode 26 or later in /Applications and select it with `xcode-select`; the Command Line Tools alone do not include Icon Composer or actool."
        case let .toolLaunchFailed(tool, cause):
            "Could not start \(tool): \(cause.localizedDescription)"
        case let .toolFailed(tool, arguments, status, elapsed, stderr):
            "\(tool) \(arguments) exited with status \(status) after \(String(format: "%.1f", elapsed))s. stderr: \(stderr.isEmpty ? "(empty)" : stderr)"
        case let .toolTimedOut(tool, arguments, elapsed):
            "\(tool) \(arguments) did not finish within \(String(format: "%.1f", elapsed))s and was stopped."
        }
    }
}
