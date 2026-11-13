import AppKit
import Foundation

// Generates every Bitekey icon file from the constants below, so the committed
// vector sources and bitmaps trace back to one reviewed place instead of hand
// edits in a design tool. Run from `make icons`; uses only system frameworks
// because third-party renderers carry supply-chain and SVG-parser risk.
// Usage: swift scripts/render-icons.swift sources

// MARK: - Constants

/// Grayscale palette of the mark; the brand is deliberately color-free.
private enum Palette {
    static let skirt = RGBColor(hex: 0x2A2A2A)
    static let faceSide = RGBColor(hex: 0x3A3A3A)
    static let face = RGBColor(hex: 0x505050)
    static let ink = RGBColor(hex: 0xF2F2F0)
    /// Template images carry meaning only in alpha, so the menu mark is pure black.
    static let template = RGBColor(hex: 0x000000)
}

/// Keycap shapes in the 140-unit drawing the owner approved; every other
/// space is derived from it so the approved proportions survive.
private enum KeyGeometry {
    static let drawingSize = 140.0
    static let skirt = RoundedRect(x: 10, y: 10, width: 120, height: 120, radius: 24)
    /// The lip shows below the face so the top reads as raised.
    static let lip = RoundedRect(x: 20, y: 13, width: 100, height: 94, radius: 18)
    static let face = RoundedRect(x: 24, y: 14, width: 92, height: 86, radius: 15)
}

/// Values shared by both legends so the app and menu marks fade the same way.
private enum LegendSpace {
    /// Legend geometry is authored in a square of this size, then placed on the key.
    static let size = 100.0
    static let peakOpacity = 0.80
    static let floorOpacity = 0.15
    static let tileCornerRatio = 0.25
}

/// H3 "Fine grid": the dense app-icon legend, readable at Dock sizes.
private enum AppLegend {
    static let grid = GridSpec(count: 5, pad: 18, dotRadius: 4.5, pick: GridCell(column: 3, row: 1), tileSize: 17, fall: 0.17)
    /// One uniform scale keeps dots round; the sketches' non-uniform scale squashed them.
    static let scale = 0.86
}

/// M2 "4×4": fewer, larger dots so the menu mark survives 18 px.
private enum MenuLegend {
    static let grid = GridSpec(count: 4, pad: 22, dotRadius: 6.5, pick: GridCell(column: 2, row: 1), tileSize: 22, fall: 0.22)
    static let outline = RoundedRect(x: 14, y: 14, width: 112, height: 112, radius: 24)
    static let strokeWidth = 11.0
    static let offset = 22.0
    static let scale = 0.96
}

/// The `.icon` canvas; the skirt region of the drawing fills it edge to edge
/// because macOS draws its own squircle and glass around the solid fill.
private enum Canvas {
    static let size = 1024.0
    static var mapping: Placement {
        let scale = size / KeyGeometry.skirt.width
        return Placement(dx: -KeyGeometry.skirt.x * scale, dy: -KeyGeometry.skirt.y * scale, scale: scale)
    }
}

/// Output locations, relative to the repository root.
private enum OutputPath {
    static let iconManifest = "Resources/AppIcon.icon/icon.json"
    static let assetsDirectory = "Resources/AppIcon.icon/Assets"
    static let menuSource = "Resources/Icon/MenuBarIcon.svg"
}

/// Layers of the `.icon` bundle, declared in paint order, bottom first.
private enum IconLayer: String, CaseIterable {
    case face = "Face"
    case legend = "Legend"

    /// Icon Composer lists layers top first; a probe with `ictool` hid the
    /// legend under the face when they were listed bottom first.
    static var manifestOrder: [IconLayer] {
        allCases.reversed()
    }

    var fileName: String {
        "\(rawValue).svg"
    }

    var path: String {
        "\(OutputPath.assetsDirectory)/\(fileName)"
    }

    /// An exhaustive switch makes a new layer fail to compile until it has artwork.
    var svg: String {
        switch self {
        case .face: faceLayerSVG()
        case .legend: legendLayerSVG()
        }
    }
}

/// `icon.json` values probed against `ictool` and `actool` on Xcode 27.2.
private enum IconManifest {
    static let platform = "macOS"
    static let colorSpace = "srgb"
    static let componentDigits = 5
    static let alpha = 1.0
}

/// SVG text settings; fixed precision keeps reruns byte-identical.
private enum SVGFormat {
    static let namespace = "http://www.w3.org/2000/svg"
    static let fractionDigits = 3
}

// MARK: - Model

private struct RGBColor {
    private static let channelMax = 255.0
    private static let redShift = 16
    private static let greenShift = 8
    private static let channelMask = 0xFF

    let red: Int
    let green: Int
    let blue: Int

    init(hex: Int) {
        red = (hex >> Self.redShift) & Self.channelMask
        green = (hex >> Self.greenShift) & Self.channelMask
        blue = hex & Self.channelMask
    }

    var svg: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// Icon Composer stores color as unit components, not hex.
    func manifest(digits: Int) -> String {
        [red, green, blue].map { String(format: "%.\(digits)f", Double($0) / Self.channelMax) }.joined(separator: ",")
    }
}

private struct RoundedRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let radius: Double

    var centerX: Double {
        x + width / 2
    }

    var centerY: Double {
        y + height / 2
    }
}

private struct GridCell: Equatable {
    let column: Int
    let row: Int

    func distance(to other: GridCell) -> Int {
        abs(column - other.column) + abs(row - other.row)
    }
}

/// One legend variant; H3 and M2 differ only in these values, so a single
/// emitter keeps their fade rule identical.
private struct GridSpec {
    let count: Int
    let pad: Double
    let dotRadius: Double
    let pick: GridCell
    let tileSize: Double
    /// Opacity lost per grid step away from the picked tile.
    let fall: Double

    var step: Double {
        (LegendSpace.size - 2 * pad) / Double(count - 1)
    }

    func center(_ index: Int) -> Double {
        pad + Double(index) * step
    }

    func opacity(at cell: GridCell) -> Double {
        max(LegendSpace.floorOpacity, LegendSpace.peakOpacity - fall * Double(cell.distance(to: pick) - 1))
    }
}

/// Uniform scale then offset; only uniform scales are allowed so dots stay round.
private struct Placement {
    let dx: Double
    let dy: Double
    let scale: Double

    func then(_ outer: Placement) -> Placement {
        Placement(dx: dx * outer.scale + outer.dx, dy: dy * outer.scale + outer.dy, scale: scale * outer.scale)
    }

    func apply(_ rect: RoundedRect) -> RoundedRect {
        RoundedRect(x: rect.x * scale + dx, y: rect.y * scale + dy, width: rect.width * scale, height: rect.height * scale, radius: rect.radius * scale)
    }

    var svgTransform: String {
        "translate(\(svgNumber(dx)),\(svgNumber(dy))) scale(\(svgNumber(scale)))"
    }
}

private enum RenderFailure: LocalizedError {
    case invalidArguments([String])
    case writeFailed(path: String, cause: Error)
    case invalidOutput(path: String, reason: String)
    case repositoryRootNotFound(checked: String)
    case toolFailed(tool: String, status: Int32, elapsed: TimeInterval)
    case toolTimedOut(tool: String, elapsed: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(arguments):
            "Expected one command (\(Command.allCases.map(\.rawValue).joined(separator: " | "))), got: \(arguments)."
        case let .writeFailed(path, cause):
            "Could not write \(path): \(cause.localizedDescription)"
        case let .invalidOutput(path, reason):
            "Generated \(path) failed its self-check: \(reason)"
        case let .repositoryRootNotFound(checked):
            "Refusing to write icons: \(checked) is missing, so the script is not in the Bitekey repository's scripts folder."
        case let .toolFailed(tool, status, elapsed):
            "\(tool) exited with status \(status) after \(String(format: "%.1f", elapsed))s."
        case let .toolTimedOut(tool, elapsed):
            "\(tool) did not finish within \(String(format: "%.1f", elapsed))s and was stopped."
        }
    }
}

// MARK: - SVG

/// Fixed precision with trailing zeros dropped, so output is short and stable.
private func svgNumber(_ value: Double) -> String {
    var text = String(format: "%.\(SVGFormat.fractionDigits)f", value)
    while text.contains("."), text.hasSuffix("0") {
        text.removeLast()
    }
    if text.hasSuffix(".") {
        text.removeLast()
    }
    return text == "-0" ? "0" : text
}

private func svgDocument(size: Double, body: [String]) -> String {
    let side = svgNumber(size)
    let header = "<svg xmlns=\"\(SVGFormat.namespace)\" width=\"\(side)\" height=\"\(side)\" viewBox=\"0 0 \(side) \(side)\">"
    return ([header] + body + ["</svg>"]).joined(separator: "\n") + "\n"
}

private func svgRect(_ rect: RoundedRect, attributes: String = "") -> String {
    let geometry = "x=\"\(svgNumber(rect.x))\" y=\"\(svgNumber(rect.y))\" width=\"\(svgNumber(rect.width))\" height=\"\(svgNumber(rect.height))\" rx=\"\(svgNumber(rect.radius))\""
    return "<rect \([geometry, attributes].filter { !$0.isEmpty }.joined(separator: " "))/>"
}

/// Legend in its 100-unit space, row by row; the caller places it on the key.
private func legendSVG(grid: GridSpec, color: RGBColor) -> String {
    var lines = ["<g fill=\"\(color.svg)\">"]
    for row in 0 ..< grid.count {
        for column in 0 ..< grid.count {
            let cell = GridCell(column: column, row: row)
            let cx = grid.center(column)
            let cy = grid.center(row)
            if cell == grid.pick {
                let half = grid.tileSize / 2
                let tile = RoundedRect(x: cx - half, y: cy - half, width: grid.tileSize, height: grid.tileSize, radius: grid.tileSize * LegendSpace.tileCornerRatio)
                lines.append(svgRect(tile))
            } else {
                lines.append("<circle cx=\"\(svgNumber(cx))\" cy=\"\(svgNumber(cy))\" r=\"\(svgNumber(grid.dotRadius))\" opacity=\"\(svgNumber(grid.opacity(at: cell)))\"/>")
            }
        }
    }
    lines.append("</g>")
    return lines.joined(separator: "\n")
}

private func placedGroup(_ placement: Placement, content: String) -> [String] {
    ["<g transform=\"\(placement.svgTransform)\">", content, "</g>"]
}

/// Centers the 100-unit legend on the face with one uniform scale.
private var appLegendPlacement: Placement {
    let side = LegendSpace.size * AppLegend.scale
    let face = KeyGeometry.face
    return Placement(dx: face.centerX - side / 2, dy: face.centerY - side / 2, scale: AppLegend.scale)
}

private func faceLayerSVG() -> String {
    let mapping = Canvas.mapping
    return svgDocument(size: Canvas.size, body: [
        svgRect(mapping.apply(KeyGeometry.lip), attributes: "fill=\"\(Palette.faceSide.svg)\""),
        svgRect(mapping.apply(KeyGeometry.face), attributes: "fill=\"\(Palette.face.svg)\""),
    ])
}

private func legendLayerSVG() -> String {
    let placement = appLegendPlacement.then(Canvas.mapping)
    return svgDocument(size: Canvas.size, body: placedGroup(placement, content: legendSVG(grid: AppLegend.grid, color: Palette.ink)))
}

private func menuSVG() -> String {
    let outline = svgRect(MenuLegend.outline, attributes: "fill=\"none\" stroke=\"\(Palette.template.svg)\" stroke-width=\"\(svgNumber(MenuLegend.strokeWidth))\"")
    let placement = Placement(dx: MenuLegend.offset, dy: MenuLegend.offset, scale: MenuLegend.scale)
    return svgDocument(size: KeyGeometry.drawingSize, body: [outline] + placedGroup(placement, content: legendSVG(grid: MenuLegend.grid, color: Palette.template)))
}

// MARK: - icon.json

/// Mirrors the `icon.json` layout Icon Composer reads; keys are fixed by that format.
private struct IconDocument: Encodable {
    let fill: IconFill
    let groups: [IconGroup]
    let supportedPlatforms: IconPlatforms

    enum CodingKeys: String, CodingKey {
        case fill, groups
        case supportedPlatforms = "supported-platforms"
    }
}

private struct IconFill: Encodable {
    let solid: String
}

private struct IconGroup: Encodable {
    let layers: [IconLayerEntry]
}

private struct IconLayerEntry: Encodable {
    let imageName: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case imageName = "image-name"
        case name
    }
}

private struct IconPlatforms: Encodable {
    let squares: [String]
}

private func iconManifestJSON() throws -> Data {
    let alpha = String(format: "%.\(IconManifest.componentDigits)f", IconManifest.alpha)
    let solid = "\(IconManifest.colorSpace):\(Palette.skirt.manifest(digits: IconManifest.componentDigits)),\(alpha)"
    let layers = IconLayer.manifestOrder.map { IconLayerEntry(imageName: $0.fileName, name: $0.rawValue) }
    let document = IconDocument(fill: .init(solid: solid), groups: [.init(layers: layers)], supportedPlatforms: .init(squares: [IconManifest.platform]))
    let encoder = JSONEncoder()
    // Sorted keys keep the file stable across runs and Foundation releases.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        return try encoder.encode(document) + Data("\n".utf8)
    } catch {
        throw RenderFailure.writeFailed(path: OutputPath.iconManifest, cause: error)
    }
}

// MARK: - Writing and self-checks

private enum Writer {
    private static let fileManager = FileManager.default

    /// The script's own location, so `make` and direct runs write the same tree.
    private static let derivedRoot = URL(fileURLWithPath: #filePath).standardizedFileURL
        .deletingLastPathComponent().deletingLastPathComponent()
    /// Only the repository root holds this file, so its presence proves the
    /// derived root before anything is written there.
    private static let rootMarker = "Package.swift"

    /// Fails closed when the script was copied or moved, so it never writes
    /// icon files into an unrelated tree.
    static func url(for path: String) throws -> URL {
        let marker = derivedRoot.appendingPathComponent(rootMarker)
        guard fileManager.fileExists(atPath: marker.path) else {
            throw RenderFailure.repositoryRootNotFound(checked: marker.path)
        }
        return derivedRoot.appendingPathComponent(path)
    }

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

// MARK: - Commands

private enum Command: String, CaseIterable {
    case sources

    func run() throws {
        switch self {
        case .sources: try writeSources()
        }
    }

    private func writeSources() throws {
        for layer in IconLayer.allCases {
            try Writer.write(Data(layer.svg.utf8), to: layer.path)
            try Writer.checkSVG(at: layer.path, size: Canvas.size)
        }
        try Writer.write(iconManifestJSON(), to: OutputPath.iconManifest)
        try Writer.checkManifest()
        try Writer.write(Data(menuSVG().utf8), to: OutputPath.menuSource)
        try Writer.checkSVG(at: OutputPath.menuSource, size: KeyGeometry.drawingSize)
    }
}

private func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
        guard arguments.count == 1, let command = Command(rawValue: arguments[0]) else {
            throw RenderFailure.invalidArguments(arguments)
        }
        try command.run()
        return EXIT_SUCCESS
    } catch {
        fputs("render-icons: \(error.localizedDescription)\n", stderr)
        return EXIT_FAILURE
    }
}

exit(main())
