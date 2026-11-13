// Compiles the Icon Composer source into the asset catalog the app bundle
// ships. macOS 26 draws the glass app icon only from a compiled catalog that
// CFBundleIconName points to; the committed .icns alone gives a flat icon.
// Assets.car is a build product, so it is written only under `.build`.

import Foundation

/// Runs `actool` once for both callers (the margin reference and the catalog),
/// so the two always compile the same icon the same way. Every path is
/// absolute: actool hands the work to a shared `ibtoold` daemon that resolves
/// relative paths against its own working directory, which may be elsewhere.
func compileIcon(document: URL, into compiled: URL, partialPlist: URL, actool: String, in workspace: Workspace) throws {
    try ToolRun(name: Tool.actoolName, executable: actool, arguments: [
        document.path, ToolArguments.compile, compiled.path, ToolArguments.platform, ToolArguments.actoolPlatform,
        ToolArguments.minimumDeploymentTarget, minimumDeploymentTarget(), ToolArguments.appIcon, ToolArguments.appIconName,
        ToolArguments.outputPartialInfoPlist, partialPlist.path,
    ], timeout: Tool.actoolTimeout).run(in: workspace)
}

/// Read from Info.plist instead of repeated here, so the catalog can never
/// target a different macOS than `LSMinimumSystemVersion` declares.
func minimumDeploymentTarget() throws -> String {
    let url = try Writer.url(for: OutputPath.infoPlist)
    let key = "LSMinimumSystemVersion"
    do {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist[key] as? String, !version.isEmpty
        else {
            throw RenderFailure.deploymentTargetUnreadable(path: url.path, reason: "no \(key) string")
        }
        return version
    } catch let failure as RenderFailure {
        throw failure
    } catch {
        throw RenderFailure.deploymentTargetUnreadable(path: url.path, reason: error.localizedDescription)
    }
}

/// The kernel's canonical path, so `/var` and `/private/var` spellings of the
/// same folder compare equal; nil when the path does not exist.
private func canonicalPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else {
        return nil
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Canonical path of a possibly missing folder: the nearest existing ancestor
/// is resolved and the missing tail is appended, so a symlink anywhere in the
/// existing part is followed before the location is judged.
private func canonicalLocation(_ url: URL) -> String? {
    var existing = url
    var tail: [String] = []
    while canonicalPath(existing) == nil {
        guard existing.path != "/" else {
            return nil
        }
        tail.insert(existing.lastPathComponent, at: 0)
        existing.deleteLastPathComponent()
    }
    return canonicalPath(existing).map { ([$0] + tail).joined(separator: "/") }
}

/// The folder is cleared before use, so it must be strictly inside the
/// repository's `.build` folder; any other path (including `.build` itself, a
/// relative path, `..` tricks or a symlink out of it) fails closed. Real
/// locations are compared because the caller's spelling may differ (`make`
/// reports `/private/var` where the compile path says `/var`).
func validatedCatalogDirectory(_ argument: String) throws -> URL {
    let build = try Writer.url(for: OutputPath.buildDirectory).standardizedFileURL
    let refused = RenderFailure.unsafeOutputDirectory(path: argument, allowedRoot: build.path)
    guard (argument as NSString).isAbsolutePath else {
        throw refused
    }
    do {
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    } catch {
        throw RenderFailure.writeFailed(path: build.path, cause: error)
    }
    let candidate = URL(fileURLWithPath: argument, isDirectory: true).standardizedFileURL
    guard let realBuild = canonicalPath(build), let realCandidate = canonicalLocation(candidate),
          realCandidate.hasPrefix(realBuild + "/")
    else {
        throw refused
    }
    return URL(fileURLWithPath: realCandidate, isDirectory: true)
}

/// Writes `Assets.car` into `outputDirectory`, and fails if actool wrote none,
/// so a bundle can never ship without the glass icon.
func writeCatalog(outputDirectory: String) throws {
    let workspace = try Workspace.create()
    defer { workspace.remove() }
    // Resolved first, so a machine without full Xcode fails before any file is cleared.
    let tools = try XcodeTools.resolve(in: workspace)
    let output = try validatedCatalogDirectory(outputDirectory)
    let document = try Writer.url(for: OutputPath.iconDocument)
    do {
        // Clearing drops a stale catalog that could otherwise pass the check below.
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    } catch {
        throw RenderFailure.writeFailed(path: output.path, cause: error)
    }
    // The partial plist stays in the scratch folder: only the catalog ships.
    try compileIcon(document: document, into: output, partialPlist: workspace.file(ToolArguments.partialPlist),
                    actool: tools.actool, in: workspace)
    let catalog = output.appendingPathComponent(ToolArguments.compiledCatalog)
    let size = (try? FileManager.default.attributesOfItem(atPath: catalog.path)[.size] as? Int) ?? 0
    guard size > 0 else {
        throw RenderFailure.invalidOutput(path: catalog.path, reason: "actool reported success but wrote no \(ToolArguments.compiledCatalog)")
    }
}
