// The approved mark as data: palette, key geometry, legend variants and output
// paths. Every other file derives its shapes and file names from here.

import Foundation

/// Grayscale palette of the mark; the brand is deliberately color-free.
enum Palette {
    static let skirt = RGBColor(hex: 0x2A2A2A)
    static let faceSide = RGBColor(hex: 0x3A3A3A)
    static let face = RGBColor(hex: 0x505050)
    static let ink = RGBColor(hex: 0xF2F2F0)
    /// Template images carry meaning only in alpha, so the menu mark is pure black.
    static let template = RGBColor(hex: 0x000000)
}

/// Keycap shapes in the 140-unit drawing the owner approved; every other
/// space is derived from it so the approved proportions survive.
enum KeyGeometry {
    static let drawingSize = 140.0
    static let skirt = RoundedRect(x: 10, y: 10, width: 120, height: 120, radius: 24)
    /// The lip shows below the face so the top reads as raised.
    static let lip = RoundedRect(x: 20, y: 13, width: 100, height: 94, radius: 18)
    static let face = RoundedRect(x: 24, y: 14, width: 92, height: 86, radius: 15)
}

/// Values shared by both legends so the app and menu marks fade the same way.
enum LegendSpace {
    /// Legend geometry is authored in a square of this size, then placed on the key.
    static let size = 100.0
    static let peakOpacity = 0.80
    static let floorOpacity = 0.15
    static let tileCornerRatio = 0.25
}

/// H3 "Fine grid": the dense app-icon legend, readable at Dock sizes.
enum AppLegend {
    static let grid = GridSpec(count: 5, pad: 18, dotRadius: 4.5, pick: GridCell(column: 3, row: 1), tileSize: 17, fall: 0.17)
    /// One uniform scale keeps dots round; the sketches' non-uniform scale squashed them.
    static let scale = 0.86
}

/// M2 "4×4": fewer, larger dots so the menu mark survives 18 px.
enum MenuLegend {
    static let grid = GridSpec(count: 4, pad: 22, dotRadius: 6.5, pick: GridCell(column: 2, row: 1), tileSize: 22, fall: 0.22)
    static let outline = RoundedRect(x: 14, y: 14, width: 112, height: 112, radius: 24)
    static let strokeWidth = 11.0
    static let offset = 22.0
    static let scale = 0.96
}

/// The `.icon` canvas; the skirt region of the drawing fills it edge to edge
/// because macOS draws its own squircle and glass around the solid fill.
enum Canvas {
    static let size = 1024.0
    /// Derived from the skirt, so the canvas follows the approved drawing if it changes.
    static var mapping: Placement {
        let scale = size / KeyGeometry.skirt.width
        return Placement(dx: -KeyGeometry.skirt.x * scale, dy: -KeyGeometry.skirt.y * scale, scale: scale)
    }
}

/// Output locations, relative to the repository root.
enum OutputPath {
    static let iconManifest = "Resources/AppIcon.icon/icon.json"
    static let assetsDirectory = "Resources/AppIcon.icon/Assets"
    static let menuSource = "Resources/Icon/MenuBarIcon.svg"
    static let iconDocument = "Resources/AppIcon.icon"
    /// Source of truth for the minimum macOS version, so actool targets what the app claims.
    static let infoPlist = "Resources/Info.plist"
    /// The only area the catalog command may clear; it is ignored by version control.
    static let buildDirectory = ".build"
    /// AppKit picks the @2x file on Retina screens; the names are what the app loads.
    static let menuTemplate = "Resources/MenuBarIconTemplate.png"
    static let menuTemplateRetina = "Resources/MenuBarIconTemplate@2x.png"
    /// Repository brand image (social preview); it shows the same glass art the Dock does.
    static let logo = "Resources/Logo.png"
    /// Shipped instead of `actool`'s `.icns`, which stops at 256 px and is too small for the dmg.
    static let appIcon = "Resources/AppIcon.icns"
}

/// Layers of the `.icon` bundle, declared in paint order, bottom first.
enum IconLayer: String, CaseIterable {
    case face = "Face"
    case legend = "Legend"

    /// Icon Composer lists layers top first; a probe with `ictool` hid the
    /// legend under the face when they were listed bottom first.
    static var manifestOrder: [IconLayer] {
        allCases.reversed()
    }

    /// File name inside `Assets`, which is also the manifest's `image-name`.
    var fileName: String {
        "\(rawValue).svg"
    }

    /// Repository path for `Writer`.
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
enum IconManifest {
    static let platform = "macOS"
    static let colorSpace = "srgb"
    static let componentDigits = 5
    static let alpha = 1.0
}

/// SVG text settings; fixed precision keeps reruns byte-identical.
enum SVGFormat {
    static let namespace = "http://www.w3.org/2000/svg"
    static let fractionDigits = 3
}

/// One color, kept as 8-bit channels so SVG hex and manifest components agree exactly.
struct RGBColor {
    private static let channelMax = 255.0
    private static let redShift = 16
    private static let greenShift = 8
    private static let channelMask = 0xFF

    let red: Int
    let green: Int
    let blue: Int

    /// Hex literals match how the palette was approved and reviewed.
    init(hex: Int) {
        red = (hex >> Self.redShift) & Self.channelMask
        green = (hex >> Self.greenShift) & Self.channelMask
        blue = hex & Self.channelMask
    }

    /// Lowercase `#rrggbb`, so reruns emit identical text.
    var svg: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// Icon Composer stores color as unit components, not hex.
    func manifest(digits: Int) -> String {
        [red, green, blue].map { String(format: "%.\(digits)f", Double($0) / Self.channelMax) }.joined(separator: ",")
    }
}

/// A rounded rectangle in drawing units; every key and tile shape is one.
struct RoundedRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let radius: Double

    /// Used to center the legend on the face.
    var centerX: Double {
        x + width / 2
    }

    /// Used to center the legend on the face.
    var centerY: Double {
        y + height / 2
    }
}

/// A legend position; the fade is measured between cells, not points.
struct GridCell: Equatable {
    let column: Int
    let row: Int

    /// Manhattan distance, the approved fade metric: it follows keyboard rows and columns.
    func distance(to other: GridCell) -> Int {
        abs(column - other.column) + abs(row - other.row)
    }
}

/// One legend variant; H3 and M2 differ only in these values, so a single
/// emitter keeps their fade rule identical.
struct GridSpec {
    let count: Int
    let pad: Double
    let dotRadius: Double
    let pick: GridCell
    let tileSize: Double
    /// Opacity lost per grid step away from the picked tile.
    let fall: Double

    /// Spacing that puts the first and last dots exactly on the pads.
    var step: Double {
        (LegendSpace.size - 2 * pad) / Double(count - 1)
    }

    /// Same formula for rows and columns, so the grid stays square.
    func center(_ index: Int) -> Double {
        pad + Double(index) * step
    }

    /// Neighbours start at the peak and fade per step, never below the floor, so far dots stay visible.
    func opacity(at cell: GridCell) -> Double {
        max(LegendSpace.floorOpacity, LegendSpace.peakOpacity - fall * Double(cell.distance(to: pick) - 1))
    }
}

/// Uniform scale then offset; only uniform scales are allowed so dots stay round.
struct Placement {
    let dx: Double
    let dy: Double
    let scale: Double

    /// Composes placements, so the legend can be placed on the key and the key on the canvas.
    func then(_ outer: Placement) -> Placement {
        Placement(dx: dx * outer.scale + outer.dx, dy: dy * outer.scale + outer.dy, scale: scale * outer.scale)
    }

    /// Bakes the placement into shapes that are emitted without a transform.
    func apply(_ rect: RoundedRect) -> RoundedRect {
        RoundedRect(x: rect.x * scale + dx, y: rect.y * scale + dy, width: rect.width * scale, height: rect.height * scale, radius: rect.radius * scale)
    }

    /// For groups that keep their own coordinates, such as the legend.
    var svgTransform: String {
        "translate(\(svgNumber(dx)),\(svgNumber(dy))) scale(\(svgNumber(scale)))"
    }
}
