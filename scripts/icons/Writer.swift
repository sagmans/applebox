// The only code that writes into the repository. It guards the root and
// reads generated files back, so a bad output fails here, not in the app.

import AppKit
import Foundation

/// Every repository write and read-back goes through here, so the root guard
/// cannot be skipped.
enum Writer {
    private static let fileManager = FileManager.default

    /// This file's compile-time path. The binary lives in `.build`, not next to
    /// its sources, so the root comes from where the source was compiled, not
    /// from the binary or the working directory. `make icons` passes absolute
    /// source paths so this is absolute.
    private static let sourceFile = #filePath
    /// Folders between this file and the repository root: `scripts/icons/`.
    private static let sourceDepth = 2
    /// Only the repository root holds this file, so its presence proves the
    /// derived root before anything is written there.
    private static let rootMarker = "Package.swift"

    /// Repository root derived from `sourceFile`; nil when the compile path is
    /// relative, because a relative path would resolve against the caller's
    /// working directory.
    private static var derivedRoot: URL? {
        guard (sourceFile as NSString).isAbsolutePath else {
            return nil
        }
        var root = URL(fileURLWithPath: sourceFile).standardizedFileURL.deletingLastPathComponent()
        for _ in 0 ..< sourceDepth {
            root.deleteLastPathComponent()
        }
        return root
    }

    /// Fails closed when the sources were copied, moved or compiled with
    /// relative paths, so it never writes icon files into an unrelated tree.
    static func url(for path: String) throws -> URL {
        guard let root = derivedRoot else {
            throw RenderFailure.repositoryRootNotFound(checked: sourceFile)
        }
        let marker = root.appendingPathComponent(rootMarker)
        guard fileManager.fileExists(atPath: marker.path) else {
            throw RenderFailure.repositoryRootNotFound(checked: marker.path)
        }
        return root.appendingPathComponent(path)
    }

    /// Atomic, so an interrupted run never leaves a half-written committed file.
    static func write(_ data: Data, to path: String) throws {
        let url = try url(for: path)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw RenderFailure.writeFailed(path: path, cause: error)
        }
        print("Wrote \(path)")
    }

    /// Reads the file back through AppKit, the same loader the bitmap step uses,
    /// so a malformed SVG fails here instead of as a blank icon later.
    static func checkSVG(at path: String, size: Double) throws {
        let url = try url(for: path)
        guard let image = NSImage(contentsOf: url) else {
            throw RenderFailure.invalidOutput(path: path, reason: "AppKit could not load it as an image")
        }
        guard image.size == NSSize(width: size, height: size) else {
            throw RenderFailure.invalidOutput(path: path, reason: "size \(image.size) is not \(size)×\(size)")
        }
    }

    /// Confirms every layer the manifest names exists, so `actool` never meets a dangling reference.
    static func checkManifest() throws {
        let path = OutputPath.iconManifest
        let manifest = try url(for: path)
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            throw RenderFailure.invalidOutput(path: path, reason: "unreadable: \(error.localizedDescription)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["groups"] as? [[String: Any]]
        else {
            throw RenderFailure.invalidOutput(path: path, reason: "not the expected JSON shape")
        }
        let names = groups.flatMap { ($0["layers"] as? [[String: Any]]) ?? [] }.compactMap { $0["image-name"] as? String }
        guard names == IconLayer.manifestOrder.map(\.fileName) else {
            throw RenderFailure.invalidOutput(path: path, reason: "layers \(names) do not match the generated assets")
        }
        for layer in IconLayer.allCases where try !fileManager.fileExists(atPath: url(for: layer.path).path) {
            throw RenderFailure.invalidOutput(path: path, reason: "missing layer file \(layer.path)")
        }
    }
}
