// Entry point of the icon generator. It generates every Bitekey icon file from
// the constants in this folder, so the committed vector sources and bitmaps
// trace back to one reviewed place instead of hand edits in a design tool. It
// uses only system frameworks, because third-party renderers carry
// supply-chain and SVG-parser risk. `make icons` compiles this folder and runs
// `sources`, then `bitmaps`: `bitmaps` renders the vector files that `sources`
// writes.
// Usage: render-icons sources | bitmaps

import Foundation

/// The generator's commands; their raw values are the command-line words, so
/// the usage message and the parser cannot drift apart.
enum Command: String, CaseIterable {
    case sources
    case bitmaps

    /// One exhaustive switch, so a new command fails to compile until it runs.
    func run() throws {
        switch self {
        case .sources: try writeSources()
        case .bitmaps: try writeBitmaps()
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
