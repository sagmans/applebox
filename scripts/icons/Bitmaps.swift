// Renders the bitmaps (`bitmaps` command) and checks them before writing:
// template pixels for the menu bar, and the macOS margin for the app icon.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Menu-bar status item bitmaps; AppKit sizes status items in points.
enum MenuBitmap {
    static let pointSize = 18
    static let outputs: [(path: String, scale: Int)] = [
        (OutputPath.menuTemplate, 1),
        (OutputPath.menuTemplateRetina, 2),
    ]
    /// Share of the ideal outline ring's area that must be visible. The ring
    /// alone is about 74 px at 18 px and 296 px at 36 px; antialiasing and the
    /// dots raise the real counts to 202 and 666. Half the ring is far below
    /// any correct render, yet blank or mostly missing art is far below it.
    static let minimumOutlineShare = 0.5
    /// A rounded rectangle's perimeter is its square perimeter minus, at each
    /// of the 4 corners, the 2r of straight edge replaced by a quarter circle.
    private static let cornerCount = 4.0

    /// Minimum count of pixels with alpha > 0, from the outline in the
    /// approved drawing, so the floor follows the mark if it changes.
    static func minimumVisiblePixels(pixels: Int) -> Int {
        let outline = MenuLegend.outline
        let straight = 2 * (outline.width + outline.height)
        let perimeter = straight - cornerCount * (2 * outline.radius - Double.pi * outline.radius / 2)
        let scale = Double(pixels) / KeyGeometry.drawingSize
        let ringArea = perimeter * MenuLegend.strokeWidth * scale * scale
        return Int(ringArea * minimumOutlineShare)
    }
}

/// App-icon bitmaps rendered by `ictool` and padded to the macOS icon margin.
enum AppIconBitmap {
    /// `actool`'s compiled 256 px image (`icon_128x128@2x`) is the live
    /// reference for the macOS margin, because `ictool` renders full bleed.
    static let referencePixels = 256
    static let referenceFileName = "icon_128x128@2x.png"
    /// Opaque body width in that reference, measured on Xcode 27.2: the body
    /// spans pixels 25 to 230 at alpha >= `bodyAlpha`. The soft drop shadow
    /// around it is excluded, because `ictool` draws no shadow, so matching
    /// the shadow box would make the body 8% larger than system icons. It
    /// equals Apple's 824-of-1024 grid; the margin self-check revalidates it
    /// against `actool` on every run.
    static let referenceBodyPixels = 206.0
    static let marginRatio = referenceBodyPixels / Double(referencePixels)
    /// Separates the opaque body from the drop shadow, which never exceeds
    /// a few percent alpha, and from the antialiased edge.
    static let bodyAlpha = 0.5
    /// Allowed difference per side between our body box and the reference.
    static let marginTolerance = 2
    /// `iconutil` requires exactly these point sizes and scales in an iconset.
    static let pointSizes = [16, 32, 128, 256, 512]
    static let scales = [1, 2]
    static let logoPixels = 1024
    /// `iconutil` names: `icon_<points>x<points>[@<scale>x].png`.
    static let iconsetPrefix = "icon_"
    static let iconsetSizeSeparator = "x"
    static let iconsetScaleMarker = "@"

    /// Every file `iconutil` expects, with the pixel size of each, so one
    /// render per pixel size can fill several entries.
    static var iconsetEntries: [(fileName: String, pixels: Int)] {
        pointSizes.flatMap { points in
            scales.map { scale in
                let suffix = scale == 1 ? "" : "\(iconsetScaleMarker)\(scale)\(iconsetSizeSeparator)"
                let name = "\(iconsetPrefix)\(points)\(iconsetSizeSeparator)\(points)\(suffix).\(Scratch.pngExtension)"
                return (name, points * scale)
            }
        }
    }

    /// Art size inside a padded canvas, from the measured margin.
    static func artPixels(for pixels: Int) -> Int {
        Int((Double(pixels) * marginRatio).rounded())
    }
}

/// Raster format of every generated bitmap. Eight-bit sRGB with alpha is
/// what `iconutil` and the menu bar expect, and a fixed format keeps the
/// encoded bytes identical across runs.
enum BitmapFormat {
    static let bitsPerComponent = 8
    static let samplesPerPixel = 4
    static let alphaInfo = CGImageAlphaInfo.premultipliedLast
    static let colorSpace = CGColorSpace.sRGB
    static let channelMax = 255
    /// Template images must be pure black wherever they are visible.
    static let templateColorValue = 0
}

/// Alpha bounding box of the pixels at or above a threshold, in image rows
/// from the top, so it compares directly with what a viewer shows.
struct PixelBox: Equatable, CustomStringConvertible {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    /// Readable in the margin log line and error messages.
    var description: String {
        "x \(minX)...\(maxX), y \(minY)...\(maxY) (\(maxX - minX + 1)×\(maxY - minY + 1))"
    }

    /// The largest per-side difference, so one number decides the check.
    func maxSideDifference(to other: PixelBox) -> Int {
        [abs(minX - other.minX), abs(minY - other.minY), abs(maxX - other.maxX), abs(maxY - other.maxY)].max() ?? 0
    }

    /// Uses AppKit's color access, so `ictool`, `actool` and our own bitmaps
    /// compare alike whatever their bit depth; nil when nothing reaches the threshold.
    init?(of rep: NSBitmapImageRep, minimumAlpha: Double) {
        var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= minimumAlpha {
                let current = bounds ?? (x, y, x, y)
                bounds = (min(current.minX, x), min(current.minY, y), max(current.maxX, x), max(current.maxY, y))
            }
        }
        guard let bounds else { return nil }
        (minX, minY, maxX, maxY) = bounds
    }
}

/// Every bitmap is drawn into the same fixed format, so encoded bytes depend
/// only on the art, which keeps reruns byte-identical.
func drawBitmap(pixels: Int, path: String, draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
    guard let space = CGColorSpace(name: BitmapFormat.colorSpace),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: BitmapFormat.bitsPerComponent,
                                  bytesPerRow: 0, space: space, bitmapInfo: BitmapFormat.alphaInfo.rawValue)
    else {
        throw RenderFailure.renderFailed(path: path, reason: "could not create a \(pixels)×\(pixels) sRGB bitmap context")
    }
    draw(context)
    guard let image = context.makeImage() else {
        throw RenderFailure.renderFailed(path: path, reason: "could not read back the \(pixels)×\(pixels) bitmap")
    }
    return NSBitmapImageRep(cgImage: image)
}

/// Draws through AppKit's SVG loader, the same one `sources` validates with,
/// so the bitmap matches what the self-check accepted.
func rasterize(svg: URL, pixels: Int) throws -> NSBitmapImageRep {
    guard let data = try? Data(contentsOf: svg), let image = NSImage(data: data) else {
        throw RenderFailure.unreadableInput(path: svg.path, reason: "AppKit could not load it as an image")
    }
    return try drawBitmap(pixels: pixels, path: svg.path) { context in
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    }
}

/// ImageIO writes no timestamp or other per-run metadata into PNGs, unlike
/// a file copy that keeps the source tool's chunks.
func pngData(_ rep: NSBitmapImageRep, path: String) throws -> Data {
    let data = NSMutableData()
    guard let image = rep.cgImage,
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else {
        throw RenderFailure.renderFailed(path: path, reason: "could not start the PNG encoder")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RenderFailure.renderFailed(path: path, reason: "the PNG encoder failed")
    }
    return data as Data
}

/// Decodes exactly the bytes a check is about, so checks never trust an
/// in-memory image that the encoder could have changed.
func decodedBitmap(_ data: Data, path: String) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(data: data) else {
        throw RenderFailure.unreadableInput(path: path, reason: "not a decodable bitmap")
    }
    return rep
}

/// Checks the encoded bytes about to be written, not the in-memory drawing,
/// because AppKit tints the menu icon from exactly what the file holds.
func checkTemplate(_ data: Data, path: String, pixels: Int) throws {
    let rep = try decodedBitmap(data, path: path)
    guard rep.pixelsWide == pixels, rep.pixelsHigh == pixels else {
        throw RenderFailure.badTemplate(path: path, pixel: "size \(rep.pixelsWide)×\(rep.pixelsHigh), expected \(pixels)×\(pixels)")
    }
    guard rep.bitsPerSample == BitmapFormat.bitsPerComponent, rep.samplesPerPixel == BitmapFormat.samplesPerPixel,
          rep.hasAlpha, !rep.isPlanar
    else {
        throw RenderFailure.badTemplate(path: path, pixel: "format \(rep.bitsPerSample)-bit × \(rep.samplesPerPixel) samples is not 8-bit RGBA")
    }
    let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : BitmapFormat.samplesPerPixel - 1
    var sample = [Int](repeating: 0, count: BitmapFormat.samplesPerPixel)
    var visible = 0
    for y in 0 ..< pixels {
        for x in 0 ..< pixels {
            rep.getPixel(&sample, atX: x, y: y)
            guard sample[alphaIndex] > 0 else { continue }
            visible += 1
            let color = sample.indices.filter { $0 != alphaIndex }.map { sample[$0] }
            if color.contains(where: { $0 != BitmapFormat.templateColorValue }) {
                throw RenderFailure.badTemplate(path: path, pixel: "pixel (\(x), \(y)) has samples \(sample)")
            }
        }
    }
    // Blank art passes the color rule trivially, so the check fails closed on it.
    let minimum = MenuBitmap.minimumVisiblePixels(pixels: pixels)
    guard visible >= minimum else {
        throw RenderFailure.badTemplate(path: path, pixel: "only \(visible) visible pixels, expected at least \(minimum)")
    }
}

/// Menu-bar template PNGs, encoded and checked; nothing is written yet.
func menuBitmaps() throws -> [(path: String, data: Data)] {
    let source = try Writer.url(for: OutputPath.menuSource)
    return try MenuBitmap.outputs.map { output in
        let pixels = MenuBitmap.pointSize * output.scale
        let data = try pngData(rasterize(svg: source, pixels: pixels), path: output.path)
        try checkTemplate(data, path: output.path, pixels: pixels)
        return (output.path, data)
    }
}

/// Renders full-bleed art with `ictool`, then pads it with transparent
/// pixels, because `ictool` has no option for the macOS icon margin.
struct AppIconRenderer {
    let workspace: Workspace
    let document: URL
    let ictool: String

    /// One padded icon at `pixels`, so every iconset entry and the logo share
    /// the same measured margin.
    func padded(pixels: Int) throws -> NSBitmapImageRep {
        let art = AppIconBitmap.artPixels(for: pixels)
        let rendered = try render(art: art)
        // Integer offset avoids resampling; an odd remainder puts the extra
        // pixel on one side, within the margin check's tolerance.
        let origin = (pixels - art) / 2
        return try drawBitmap(pixels: pixels, path: OutputPath.appIcon) { context in
            context.interpolationQuality = .none
            context.draw(rendered, in: CGRect(x: origin, y: origin, width: art, height: art))
        }
    }

    /// Runs `ictool` at the art size directly instead of scaling one large
    /// render, so small sizes get Icon Composer's own rendering.
    private func render(art: Int) throws -> CGImage {
        let output = workspace.file("\(Scratch.renderPrefix)\(art).\(Scratch.pngExtension)")
        let size = String(art)
        do {
            try ToolRun(name: Tool.ictoolName, executable: ictool, arguments: [
                document.path, ToolArguments.exportImage, ToolArguments.outputFile, output.path,
                ToolArguments.platform, ToolArguments.ictoolPlatform, ToolArguments.rendition, ToolArguments.ictoolRendition,
                ToolArguments.width, size, ToolArguments.height, size, ToolArguments.scale, ToolArguments.ictoolScale,
            ], timeout: Tool.ictoolTimeout).run(in: workspace)
        } catch let RenderFailure.toolTimedOut(tool, arguments, elapsed) {
            awaitOrphanedWrite(of: output)
            throw RenderFailure.toolTimedOut(tool: tool, arguments: arguments, elapsed: elapsed)
        }
        guard let data = try? Data(contentsOf: output) else {
            throw RenderFailure.unreadableInput(path: output.path, reason: "ictool reported success but wrote no file")
        }
        let rep = try decodedBitmap(data, path: output.path)
        guard rep.pixelsWide == art, rep.pixelsHigh == art, let image = rep.cgImage else {
            throw RenderFailure.renderFailed(path: output.path, reason: "ictool wrote \(rep.pixelsWide)×\(rep.pixelsHigh), expected \(art)×\(art)")
        }
        return image
    }

    /// A probe showed `ictool` hands the write to a helper that finishes
    /// after `ictool` is stopped, and it recreates missing folders. Waiting
    /// for that write lets the workspace cleanup remove the folder for good
    /// instead of racing the helper and leaving a stray temp folder.
    private func awaitOrphanedWrite(of output: URL) {
        let deadline = Date().addingTimeInterval(Tool.orphanedWriteGrace)
        while !FileManager.default.fileExists(atPath: output.path), Date() < deadline {
            Thread.sleep(forTimeInterval: Tool.orphanedWritePoll)
        }
    }
}

/// Compiles the `.icon` with `actool` and extracts its 256 px image, so the
/// margin reference comes from the toolchain that builds the app.
func actoolReference(document: URL, actool: String, in workspace: Workspace) throws -> NSBitmapImageRep {
    let compiled = try workspace.directory(Scratch.actoolDirectory)
    try ToolRun(name: Tool.actoolName, executable: actool, arguments: [
        document.path, ToolArguments.compile, compiled.path, ToolArguments.platform, ToolArguments.actoolPlatform,
        ToolArguments.minimumDeploymentTarget, ToolArguments.deploymentTarget, ToolArguments.appIcon, ToolArguments.appIconName,
        ToolArguments.outputPartialInfoPlist, compiled.appendingPathComponent(ToolArguments.partialPlist).path,
    ], timeout: Tool.actoolTimeout).run(in: workspace)
    let iconset = workspace.file("\(Scratch.referenceIconsetName).\(ToolArguments.iconsetExtension)")
    try ToolRun(name: Tool.iconutilName, executable: Tool.iconutil, arguments: [
        ToolArguments.convert, ToolArguments.iconsetType, compiled.appendingPathComponent(ToolArguments.compiledIcon).path,
        ToolArguments.output, iconset.path,
    ], timeout: Tool.iconutilTimeout).run(in: workspace)
    let reference = iconset.appendingPathComponent(AppIconBitmap.referenceFileName)
    guard let data = try? Data(contentsOf: reference) else {
        throw RenderFailure.unreadableInput(path: reference.path, reason: "actool's icon has no \(AppIconBitmap.referencePixels) px image")
    }
    let rep = try decodedBitmap(data, path: reference.path)
    guard rep.pixelsWide == AppIconBitmap.referencePixels else {
        throw RenderFailure.unreadableInput(path: reference.path, reason: "width \(rep.pixelsWide), expected \(AppIconBitmap.referencePixels)")
    }
    return rep
}

/// A full-bleed or mis-padded icon looks too big next to system icons in the
/// Finder and the dmg, so the body box must match `actool`'s.
func checkMargin(ours: NSBitmapImageRep, reference: NSBitmapImageRep) throws {
    let path = OutputPath.appIcon
    guard let ourBox = PixelBox(of: ours, minimumAlpha: AppIconBitmap.bodyAlpha),
          let referenceBox = PixelBox(of: reference, minimumAlpha: AppIconBitmap.bodyAlpha)
    else {
        throw RenderFailure.invalidOutput(path: path, reason: "an icon at \(AppIconBitmap.referencePixels) px has no opaque pixels")
    }
    let difference = ourBox.maxSideDifference(to: referenceBox)
    print("Margin at \(AppIconBitmap.referencePixels) px: actool body \(referenceBox), ours \(ourBox), max side difference \(difference) px")
    guard difference <= AppIconBitmap.marginTolerance else {
        throw RenderFailure.invalidOutput(path: path, reason: "body \(ourBox) differs from actool's \(referenceBox) by \(difference) px (limit \(AppIconBitmap.marginTolerance))")
    }
}

/// Builds the `.icns` with `iconutil` from the padded renders.
func icnsData(_ renders: [Int: Data], in workspace: Workspace) throws -> Data {
    let iconset = try workspace.directory("\(Scratch.iconsetName).\(ToolArguments.iconsetExtension)")
    for entry in AppIconBitmap.iconsetEntries {
        guard let data = renders[entry.pixels] else {
            throw RenderFailure.renderFailed(path: OutputPath.appIcon, reason: "no \(entry.pixels) px render for \(entry.fileName)")
        }
        let url = iconset.appendingPathComponent(entry.fileName)
        do {
            try data.write(to: url)
        } catch {
            throw RenderFailure.writeFailed(path: url.path, cause: error)
        }
    }
    let output = workspace.file("\(Scratch.iconsetName).\(ToolArguments.icnsType)")
    try ToolRun(name: Tool.iconutilName, executable: Tool.iconutil, arguments: [
        ToolArguments.convert, ToolArguments.icnsType, iconset.path, ToolArguments.output, output.path,
    ], timeout: Tool.iconutilTimeout).run(in: workspace)
    do {
        return try Data(contentsOf: output)
    } catch {
        throw RenderFailure.unreadableInput(path: output.path, reason: error.localizedDescription)
    }
}

/// Renders every bitmap and runs every self-check before writing anything,
/// so a failed check leaves the committed files untouched.
func writeBitmaps() throws {
    let workspace = try Workspace.create()
    defer { workspace.remove() }
    // Resolved first, so a machine without full Xcode fails before any render.
    let tools = try XcodeTools.resolve(in: workspace)
    let menu = try menuBitmaps()
    let renderer = try AppIconRenderer(workspace: workspace, document: Writer.url(for: OutputPath.iconDocument), ictool: tools.ictool)
    var renders: [Int: Data] = [:]
    let sizes = Set(AppIconBitmap.iconsetEntries.map(\.pixels) + [AppIconBitmap.logoPixels, AppIconBitmap.referencePixels])
    for pixels in sizes.sorted() {
        renders[pixels] = try pngData(renderer.padded(pixels: pixels), path: OutputPath.appIcon)
    }
    guard let referenceSized = renders[AppIconBitmap.referencePixels], let logo = renders[AppIconBitmap.logoPixels] else {
        throw RenderFailure.renderFailed(path: OutputPath.appIcon, reason: "missing the reference or logo render")
    }
    // The encoded bytes are checked, because they are what the `.icns` holds.
    let ours = try decodedBitmap(referenceSized, path: OutputPath.appIcon)
    try checkMargin(ours: ours, reference: actoolReference(document: renderer.document, actool: tools.actool, in: workspace))
    let icns = try icnsData(renders, in: workspace)
    for output in menu {
        try Writer.write(output.data, to: output.path)
    }
    try Writer.write(logo, to: OutputPath.logo)
    try Writer.write(icns, to: OutputPath.appIcon)
}
