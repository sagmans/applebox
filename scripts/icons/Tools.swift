// Runs Xcode's icon tools with fixed arguments, hard timeouts and a private
// temp folder, so a hung or missing tool fails the run with a clear reason.

import Foundation

/// Xcode tools the bitmap step runs. Every path is absolute and fixed, or
/// derived from the one developer directory `xcode-select` reports, so a
/// look-alike binary earlier in `$PATH` is never run. This does not defend
/// against a changed `xcode-select` selection or `DEVELOPER_DIR`, which are
/// trusted local configuration.
enum Tool {
    static let xcodeName = "Xcode"
    static let xcodeSelectName = "xcode-select"
    static let xcodeSelect = "/usr/bin/xcode-select"
    /// A full Xcode's developer directory is `<Xcode>.app/Contents/Developer`;
    /// the Command Line Tools' is not, and they lack both icon tools.
    static let developerSuffix = ["Contents", "Developer"]
    static let appExtension = ".app"
    /// Icon Composer's command-line renderer; Xcode ships it only inside the
    /// Icon Composer app, relative to the developer directory.
    static let ictoolName = "ictool"
    static let ictoolRelativePath = "../Applications/Icon Composer.app/Contents/Executables/ictool"
    static let actoolName = "actool"
    static let actoolRelativePath = "usr/bin/actool"
    static let iconutilName = "iconutil"
    /// Part of macOS itself, so it needs no Xcode lookup.
    static let iconutil = "/usr/bin/iconutil"
    /// Each `ictool` call takes under a second; the bound only stops a hang.
    static let ictoolTimeout: TimeInterval = 30
    /// `actool` took about 3 s in probes; the margin leaves room for a cold start.
    static let actoolTimeout: TimeInterval = 60
    static let iconutilTimeout: TimeInterval = 30
    static let lookupTimeout: TimeInterval = 30
    /// Time a stopped tool gets to exit after SIGTERM before it is killed.
    static let terminateGrace: TimeInterval = 5
    /// Bounds the wait for `ictool`'s helper to finish a write after a timeout.
    static let orphanedWriteGrace: TimeInterval = 5
    static let orphanedWritePoll: TimeInterval = 0.05
    /// Keeps a chatty tool's output readable inside one error message.
    static let stderrLimit = 2000
}

/// Arguments probed against Xcode 27.2 (`ictool --help`; `actool` has no
/// help). Named here so each tool call reads as data and one probe updates all.
enum ToolArguments {
    static let printPath = "-p"
    static let exportImage = "--export-image"
    static let outputFile = "--output-file"
    static let platform = "--platform"
    static let rendition = "--rendition"
    static let width = "--width"
    static let height = "--height"
    static let scale = "--scale"
    static let ictoolPlatform = "macOS"
    static let ictoolRendition = "Default"
    static let ictoolScale = "1"
    static let compile = "--compile"
    static let minimumDeploymentTarget = "--minimum-deployment-target"
    static let appIcon = "--app-icon"
    static let outputPartialInfoPlist = "--output-partial-info-plist"
    static let actoolPlatform = "macosx"
    static let appIconName = "AppIcon"
    static let compiledIcon = "AppIcon.icns"
    /// The compiled catalog the app bundle ships so macOS 26 draws the glass icon.
    static let compiledCatalog = "Assets.car"
    static let partialPlist = "partial-info.plist"
    /// `iconutil` flags: convert to a type, and the output path.
    static let convert = "-c"
    static let output = "-o"
    static let iconsetExtension = "iconset"
    static let icnsType = "icns"
    static let iconsetType = "iconset"
}

/// Scratch files live in one directory per run under the system temp folder,
/// so a failed run leaves nothing in the repository and nothing shared.
enum Scratch {
    static let prefix = "bitekey-icons-"
    static let iconsetName = "AppIcon"
    static let referenceIconsetName = "reference"
    static let actoolDirectory = "actool"
    static let renderPrefix = "art-"
    static let pngExtension = "png"
    static let stdoutExtension = "stdout"
    static let stderrExtension = "stderr"
}

/// One run directory under the system temp folder. Tools write their files
/// here, never in the repository, and the caller removes it on every path.
struct Workspace {
    let url: URL

    /// A fresh UUID folder per run, so parallel or leftover runs never share files.
    static func create() throws -> Workspace {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Scratch.prefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw RenderFailure.writeFailed(path: url.path, cause: error)
        }
        return Workspace(url: url)
    }

    /// Scratch file path; every tool output stays inside the run folder.
    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Some tools need an existing output folder; it stays inside the run folder.
    func directory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RenderFailure.writeFailed(path: directory.path, cause: error)
        }
        return directory
    }

    /// Cleanup is best effort: a leftover temp folder must not hide the
    /// real outcome of the run, and the system purges the temp folder.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Starts a tool directly (never through a shell) with a hard deadline.
struct ToolRun {
    let name: String
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval

    /// Output goes to files, not pipes, so a tool that writes more than a
    /// pipe buffer can never block on a reader that waits for it to exit.
    /// Returns stdout, which `xcode-select -p` uses for its answer.
    @discardableResult
    func run(in workspace: Workspace) throws -> String {
        // A relative path would resolve against the caller's working directory.
        guard (executable as NSString).isAbsolutePath, FileManager.default.isExecutableFile(atPath: executable) else {
            throw RenderFailure.toolMissing(tool: name, path: executable)
        }
        let logName = "\(name)-\(UUID().uuidString)"
        let stdoutURL = workspace.file("\(logName).\(Scratch.stdoutExtension)")
        let stderrURL = workspace.file("\(logName).\(Scratch.stderrExtension)")
        let (stdoutHandle, stderrHandle) = try openLogs(stdoutURL, stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let start = Date()
        do {
            try process.run()
        } catch {
            throw RenderFailure.toolLaunchFailed(tool: name, cause: error)
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            stop(process, exited: exited)
            throw RenderFailure.toolTimedOut(tool: name, arguments: arguments, elapsed: Date().timeIntervalSince(start))
        }
        guard process.terminationReason == .exit, process.terminationStatus == EXIT_SUCCESS else {
            throw RenderFailure.toolFailed(tool: name, arguments: arguments, status: process.terminationStatus,
                                           elapsed: Date().timeIntervalSince(start),
                                           stdout: String(logText(stdoutURL).prefix(Tool.stderrLimit)),
                                           stderr: String(logText(stderrURL).prefix(Tool.stderrLimit)))
        }
        return logText(stdoutURL)
    }

    /// A log that cannot be read or decoded becomes a visible marker, so the
    /// real tool failure is still reported instead of a secondary read error.
    private func logText(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "(log unreadable)"
        }
        return String(bytes: data, encoding: .utf8) ?? "(log not UTF-8)"
    }

    /// Creates the log files up front, because `FileHandle(forWritingTo:)`
    /// cannot create them, and a missing log must fail before the tool starts.
    private func openLogs(_ stdoutURL: URL, _ stderrURL: URL) throws -> (FileHandle, FileHandle) {
        for url in [stdoutURL, stderrURL] where !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw RenderFailure.writeFailed(path: url.path, cause: CocoaError(.fileWriteUnknown))
        }
        do {
            return try (FileHandle(forWritingTo: stdoutURL), FileHandle(forWritingTo: stderrURL))
        } catch {
            throw RenderFailure.writeFailed(path: stdoutURL.path, cause: error)
        }
    }

    /// SIGTERM first so the tool can clean up; SIGKILL if it ignores that,
    /// so the generator never leaves a stuck child behind.
    private func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + Tool.terminateGrace) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }
}

/// Absolute paths of the Xcode icon tools, all from one developer directory,
/// so `ictool` and `actool` always come from the same Xcode.
struct XcodeTools {
    let ictool: String
    let actool: String

    /// Asks `xcode-select -p` instead of `xcrun --find`, because `xcrun` falls
    /// back to `$PATH` when the developer directory lacks a tool. A developer
    /// directory outside an `.app` is the Command Line Tools, which lack both
    /// icon tools, so that case fails as missing Xcode before any tool runs.
    static func resolve(in workspace: Workspace) throws -> XcodeTools {
        let lookup = ToolRun(name: Tool.xcodeSelectName, executable: Tool.xcodeSelect,
                             arguments: [ToolArguments.printPath], timeout: Tool.lookupTimeout)
        let reported: String
        do {
            reported = try lookup.run(in: workspace).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let RenderFailure.toolFailed(_, _, status, _, _, stderr) {
            // Keeps the lookup's exit status and stderr, so the missing-Xcode
            // error still shows why `xcode-select` refused.
            throw RenderFailure.toolMissing(tool: Tool.xcodeName, path: "\(Tool.xcodeSelect) \(ToolArguments.printPath) reports no developer directory (status \(status): \(stderr))")
        }
        guard (reported as NSString).isAbsolutePath else {
            throw RenderFailure.toolMissing(tool: Tool.xcodeName, path: "developer directory \"\(reported)\" is not an absolute path")
        }
        let developer = URL(fileURLWithPath: reported).standardizedFileURL
        let components = developer.pathComponents
        let bundle = components.dropLast(Tool.developerSuffix.count).last ?? ""
        guard Array(components.suffix(Tool.developerSuffix.count)) == Tool.developerSuffix, bundle.hasSuffix(Tool.appExtension) else {
            throw RenderFailure.toolMissing(tool: Tool.xcodeName, path: "developer directory \(developer.path) is not inside an Xcode .app, so only the Command Line Tools are selected")
        }
        return XcodeTools(ictool: developer.appendingPathComponent(Tool.ictoolRelativePath).standardizedFileURL.path,
                          actool: developer.appendingPathComponent(Tool.actoolRelativePath).standardizedFileURL.path)
    }
}
