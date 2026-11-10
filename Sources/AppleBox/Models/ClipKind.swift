import Foundation
import SwiftUI

/// What a clipboard entry looks like to the user, so rows can pick an icon and
/// preview style without each view re-inspecting the raw text.
nonisolated enum ClipKind: Sendable, Equatable {
    case text
    case link(host: String)
    case code
    case color(Color)
    case image
    case file

    // MARK: - Classification constants

    /// Short, long and alpha hex forms are all common in design tools; anything else is plain text.
    private static let hexColorPattern = "^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"
    /// Functional notations are matched loosely here and validated numerically afterwards.
    private static let functionalColorPattern = "^(rgba?|hsl)\\(([^()]*)\\)$"
    /// Only web links get the link treatment; other schemes are not safe to open from a preview.
    private static let linkSchemes: Set<String> = ["http", "https"]
    private static let fileScheme = "file"
    private static let hexRadix = 16
    private static let hexDigitsShort = 3
    private static let hexDigitsLong = 6
    private static let hexDigitsAlpha = 8
    private static let byteMax = 255.0
    private static let percentMax = 100.0
    private static let degreesMax = 360.0
    private static let hueSectors = 6.0
    private static let argumentSeparator = ","
    private static let percentSuffix = "%"

    /// Pure function of the item so it can run on a background queue while rows are built.
    static func classify(_ item: ClipboardItem) -> ClipKind {
        if item.contentType == .image {
            return .image
        }

        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = singleURL(trimmed) {
            if let scheme = url.scheme?.lowercased() {
                if linkSchemes.contains(scheme), let host = url.host, !host.isEmpty {
                    return .link(host: host)
                }
                if scheme == fileScheme {
                    return .file
                }
            }
        }
        if let color = parseColor(trimmed) {
            return .color(color)
        }
        if isCodeLike(item.content) {
            return .code
        }
        return .text
    }

    /// Heuristic to detect code-like content for monospace formatting.
    /// Detects: common code patterns, indentation, brackets, semicolons, etc.
    static func isCodeLike(_ text: String) -> Bool {
        // Code indicators
        let codePatterns = [
            "func ", "class ", "struct ", "enum ", "let ", "var ", "import ", // Swift
            "function ", "const ", "=>", "===", "!==", // JavaScript
            "def ", "if __name__", "import ", "from ", // Python
            "{", "}", "[", "]", "();", "();", "->", "::", // Common syntax
        ]

        let lowercased = text.lowercased()

        // Check for code patterns
        for pattern in codePatterns {
            if lowercased.contains(pattern.lowercased()) {
                return true
            }
        }

        // Check for indentation (multiple leading spaces/tabs on lines)
        let lines = text.components(separatedBy: "\n")
        let indentedLines = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        if indentedLines.count > 2 {
            return true
        }

        return false
    }

    // MARK: - Private helpers

    /// A clip counts as a link or file only when the whole text is one URL; prose that merely
    /// contains a URL stays text so its surrounding words remain searchable and readable.
    private static func singleURL(_ trimmed: String) -> URL? {
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return URL(string: trimmed)
    }

    /// Returns nil for anything that matches a color shape but has out-of-range numbers, so
    /// malformed values fall back to the other kinds instead of showing a wrong swatch.
    private static func parseColor(_ text: String) -> Color? {
        if text.range(of: hexColorPattern, options: .regularExpression) != nil {
            return parseHex(String(text.dropFirst()))
        }
        guard text.range(of: functionalColorPattern, options: [.regularExpression, .caseInsensitive]) != nil,
              let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")") else { return nil }
        let name = text[..<open].lowercased()
        let args = text[text.index(after: open) ..< close]
            .components(separatedBy: argumentSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch name {
        case "rgb", "rgba": return parseRGB(args, allowsAlpha: name == "rgba")
        case "hsl": return parseHSL(args)
        default: return nil
        }
    }

    /// Expands short hex so one code path handles all three notations.
    private static func parseHex(_ digits: String) -> Color? {
        var expanded = digits
        if digits.count == hexDigitsShort {
            expanded = digits.map { "\($0)\($0)" }.joined()
        }
        guard expanded.count == hexDigitsLong || expanded.count == hexDigitsAlpha,
              let value = UInt32(expanded, radix: hexRadix) else { return nil }
        let hasAlpha = expanded.count == hexDigitsAlpha
        let shift: (Int) -> Double = { position in
            Double((value >> UInt32(position * 8)) & 0xFF) / byteMax
        }
        return hasAlpha
            ? Color(.sRGB, red: shift(3), green: shift(2), blue: shift(1), opacity: shift(0))
            : Color(.sRGB, red: shift(2), green: shift(1), blue: shift(0), opacity: 1)
    }

    /// Accepts 3 channels, plus an alpha only for `rgba`, to match CSS spelling.
    private static func parseRGB(_ args: [String], allowsAlpha: Bool) -> Color? {
        let expected = allowsAlpha ? 4 : 3
        guard args.count == expected else { return nil }
        let channels = args.prefix(3).compactMap { Double($0) }
        guard channels.count == 3, channels.allSatisfy({ (0 ... byteMax).contains($0) }) else { return nil }
        let alpha = allowsAlpha ? Double(args[3]) : 1
        guard let alpha, (0 ... 1).contains(alpha) else { return nil }
        return Color(.sRGB, red: channels[0] / byteMax, green: channels[1] / byteMax, blue: channels[2] / byteMax, opacity: alpha)
    }

    /// Converts HSL to RGB because SwiftUI's `Color` has no HSL initializer in sRGB.
    private static func parseHSL(_ args: [String]) -> Color? {
        guard args.count == 3,
              let hue = Double(args[0]),
              let sat = percent(args[1]),
              let light = percent(args[2]),
              (0 ... degreesMax).contains(hue) else { return nil }
        let chroma = (1 - abs(2 * light - 1)) * sat
        let sector = (hue / degreesMax * hueSectors)
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = light - chroma / 2
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, secondary, 0)
        case 1: (secondary, chroma, 0)
        case 2: (0, chroma, secondary)
        case 3: (0, secondary, chroma)
        case 4: (secondary, 0, chroma)
        default: (chroma, 0, secondary)
        }
        return Color(.sRGB, red: red + base, green: green + base, blue: blue + base, opacity: 1)
    }

    /// HSL saturation and lightness are written as percentages; normalizing to 0...1 here.
    private static func percent(_ text: String) -> Double? {
        guard text.hasSuffix(percentSuffix),
              let value = Double(text.dropLast(percentSuffix.count)),
              (0 ... percentMax).contains(value) else { return nil }
        return value / percentMax
    }
}
