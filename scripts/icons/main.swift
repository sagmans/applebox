// Entry point of the icon generator. It generates every Bitekey icon file from
// the constants in this folder, so the committed vector sources and bitmaps
// trace back to one reviewed place instead of hand edits in a design tool. It
// uses only system frameworks, because third-party renderers carry
// supply-chain and SVG-parser risk. `make icons` compiles this folder and runs
// `sources`, then `bitmaps`: `bitmaps` renders the vector files that `sources`
// writes. `make bundle` runs `catalog` to compile the glass icon for the app.
// Usage: render-icons sources | bitmaps | catalog <output-dir>

import Foundation

/// The generator's commands; their raw values are the command-line words, so
/// the usage message and the parser cannot drift apart.
enum Command: String, CaseIterable {
    case sources
    case bitmaps
    case catalog

    /// Shown in the usage message, so the operand a command needs is visible.
    var usage: String {
        switch self {
        case .sources, .bitmaps: rawValue
        case .catalog: "\(rawValue) <output-dir>"
        }
    }

    /// Operands after the command word; a mismatch is rejected before any work.
    var operandCount: Int {
        switch self {
        case .sources, .bitmaps: 0
        case .catalog: 1
        }
    }

    /// One exhaustive switch, so a new command fails to compile until it runs.
    func run(operands: [String]) throws {
        switch self {
        case .sources: try writeSources()
        case .bitmaps: try writeBitmaps()
        case .catalog: try writeCatalog(outputDirectory: operands[0])
        }
    }

    /// Writes each source, then reads it back, so a bad file stops the run
    /// before `bitmaps` or `actool` consume it.
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

/// The one place that reports a failure, so each error is printed once and
/// `make` sees a non-zero exit.
func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
        guard let word = arguments.first, let command = Command(rawValue: word), arguments.count == command.operandCount + 1 else {
            throw RenderFailure.invalidArguments(arguments)
        }
        try command.run(operands: Array(arguments.dropFirst()))
        return EXIT_SUCCESS
    } catch {
        fputs("render-icons: \(error.localizedDescription)\n", stderr)
        return EXIT_FAILURE
    }
}

exit(main())
