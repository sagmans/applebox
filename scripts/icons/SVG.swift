// Emits the vector sources (`sources` command) from the model, as fixed-precision
// SVG text and the Icon Composer manifest, so reruns are byte-identical.

import Foundation

/// Fixed precision with trailing zeros dropped, so output is short and stable.
func svgNumber(_ value: Double) -> String {
    var text = String(format: "%.\(SVGFormat.fractionDigits)f", value)
    while text.contains("."), text.hasSuffix("0") {
        text.removeLast()
    }
    if text.hasSuffix(".") {
        text.removeLast()
    }
    return text == "-0" ? "0" : text
}

/// Square document with a matching viewBox, so AppKit and Icon Composer agree on its size.
func svgDocument(size: Double, body: [String]) -> String {
    let side = svgNumber(size)
    let header = "<svg xmlns=\"\(SVGFormat.namespace)\" width=\"\(side)\" height=\"\(side)\" viewBox=\"0 0 \(side) \(side)\">"
    return ([header] + body + ["</svg>"]).joined(separator: "\n") + "\n"
}

/// One emitter for every rectangle, so all share the same number format.
func svgRect(_ rect: RoundedRect, attributes: String = "") -> String {
    let geometry = "x=\"\(svgNumber(rect.x))\" y=\"\(svgNumber(rect.y))\" width=\"\(svgNumber(rect.width))\" height=\"\(svgNumber(rect.height))\" rx=\"\(svgNumber(rect.radius))\""
    return "<rect \([geometry, attributes].filter { !$0.isEmpty }.joined(separator: " "))/>"
}

/// Legend in its 100-unit space, row by row; the caller places it on the key.
func legendSVG(grid: GridSpec, color: RGBColor) -> String {
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

/// Wraps content in one transform group, so it keeps its authored coordinates.
func placedGroup(_ placement: Placement, content: String) -> [String] {
    ["<g transform=\"\(placement.svgTransform)\">", content, "</g>"]
}

/// Centers the 100-unit legend on the face with one uniform scale.
var appLegendPlacement: Placement {
    let side = LegendSpace.size * AppLegend.scale
    let face = KeyGeometry.face
    return Placement(dx: face.centerX - side / 2, dy: face.centerY - side / 2, scale: AppLegend.scale)
}

/// The lip and face on the canvas; the skirt is the manifest fill, not a layer.
func faceLayerSVG() -> String {
    let mapping = Canvas.mapping
    return svgDocument(size: Canvas.size, body: [
        svgRect(mapping.apply(KeyGeometry.lip), attributes: "fill=\"\(Palette.faceSide.svg)\""),
        svgRect(mapping.apply(KeyGeometry.face), attributes: "fill=\"\(Palette.face.svg)\""),
    ])
}

/// A separate layer, so the legend paints above the face in Icon Composer's layer order.
func legendLayerSVG() -> String {
    let placement = appLegendPlacement.then(Canvas.mapping)
    return svgDocument(size: Canvas.size, body: placedGroup(placement, content: legendSVG(grid: AppLegend.grid, color: Palette.ink)))
}

/// The menu mark in the 140-unit drawing, in template black only.
func menuSVG() -> String {
    let outline = svgRect(MenuLegend.outline, attributes: "fill=\"none\" stroke=\"\(Palette.template.svg)\" stroke-width=\"\(svgNumber(MenuLegend.strokeWidth))\"")
    let placement = Placement(dx: MenuLegend.offset, dy: MenuLegend.offset, scale: MenuLegend.scale)
    return svgDocument(size: KeyGeometry.drawingSize, body: [outline] + placedGroup(placement, content: legendSVG(grid: MenuLegend.grid, color: Palette.template)))
}

/// Mirrors the `icon.json` layout Icon Composer reads; keys are fixed by that format.
struct IconDocument: Encodable {
    let fill: IconFill
    let groups: [IconGroup]
    let supportedPlatforms: IconPlatforms

    /// Icon Composer uses kebab-case keys.
    enum CodingKeys: String, CodingKey {
        case fill, groups
        case supportedPlatforms = "supported-platforms"
    }
}

/// The solid background that macOS clips to the icon shape.
struct IconFill: Encodable {
    let solid: String
}

/// One group holds both layers: the shape probed with `ictool` and `actool`.
struct IconGroup: Encodable {
    let layers: [IconLayerEntry]
}

/// A layer that points at one SVG in `Assets`.
struct IconLayerEntry: Encodable {
    let imageName: String
    let name: String

    /// Icon Composer uses kebab-case keys.
    enum CodingKeys: String, CodingKey {
        case imageName = "image-name"
        case name
    }
}

/// Limits the document to macOS, the only platform Bitekey ships on.
struct IconPlatforms: Encodable {
    let squares: [String]
}

/// Builds the manifest from the same constants as the layers, so names and colors cannot drift.
func iconManifestJSON() throws -> Data {
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
