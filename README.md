# Bitekey - Minimal macOS Launcher

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Bitekey is a minimal macOS launcher for app search and clipboard history.

## Building

Bitekey requires macOS 26 or later and Swift 6.2 or later.

```bash
swift build
```

## Running

```bash
swift run
```

## Local Install

`make install` puts a signed development copy at
`~/Applications/Bitekey.app`. Open it from Finder or run
`open ~/Applications/Bitekey.app`.

Run `make local-signing` once first. It creates a self-signed code-signing
identity, "Bitekey Local Development", in your login keychain. Local builds
sign with it, so macOS keeps the paste permission across rebuilds; you grant
it once. Without it, builds are ad-hoc signed and macOS forgets the permission
after each build. The identity is for local builds only: releases are signed
with the Developer ID and notarized (`make ship`).

If you granted the permission to an earlier build with a different signature,
turning the switch off and on is not enough: macOS keeps the old signature. In
System Settings → Privacy & Security, select Bitekey in the paste permission
pane, remove it with **−**, then add `~/Applications/Bitekey.app` with **+**.

Dev and release builds share the bundle ID, saved data, and hotkeys, so run
one at a time. Because their signatures differ, macOS asks for the paste
permission again when you switch between them.

To update, run `make install` again. It stops any running copy first. The
installer replaces the bundle and keeps saved clips, recent apps, and
preferences. `make uninstall` moves the bundle to Trash and keeps that data.

`make bundle` and `make install` need full Xcode, not only the Command Line
Tools: they compile the app icon with Xcode's asset compiler. If you change
the logo, edit the constants in `scripts/icons/` and run `make icons`. It
regenerates the icon sources, the menu-bar images, `Resources/Logo.png` and
`Resources/AppIcon.icns`. Commit those files with the change.

To opt in to startup, select **Launch at Login → Start Bitekey Automatically**
in the menu bar. Select it again to disable it. If macOS asks for approval,
choose **Open Login Items Settings** from the same submenu. You can also add or
remove the installed app under **System Settings → General → Login Items &
Extensions → Open at Login**. Disable automatic startup before uninstalling.

## Moving from AppleBox

Bitekey was named AppleBox before. Follow these steps to move.

1. Quit AppleBox. Turn off its login item.
2. Run `make local-signing`. It makes the new identity,
   "Bitekey Local Development".
3. Run `make install`. It refuses to run while AppleBox runs.
4. Open Bitekey. The first launch copies clip history, recent apps, and
   shortcut choices. AppleBox data stays unchanged.
5. Grant the paste permission to Bitekey once.
6. Check that your old clips show in the Bitekey clipboard history. Then move
   `~/Library/Application Support/AppleBox` and `~/Applications/AppleBox.app`
   to the Trash.

If your old clips do not show in step 6, the copy failed. Keep the AppleBox
data. Quit Bitekey, move `~/Library/Application Support/Bitekey` to the Trash,
and open Bitekey again. The next launch tries the copy again. Clips that
Bitekey saved before this step are lost.

## Testing

For a comprehensive testing guide, see **[docs/TESTING.md](docs/TESTING.md)**.

### Quick Start

Run all tests.

```bash
swift test
```

### Code Coverage

Run tests with code coverage and view a report.

```bash
# Run tests with coverage and show per-file report
./scripts/coverage-report.sh

# Show only the summary line
./scripts/coverage-report.sh --summary

# Generate an interactive HTML report (opens in browser)
./scripts/coverage-report.sh --html

# Output raw JSON coverage data
./scripts/coverage-report.sh --json
```

You can also run coverage manually with Swift.

```bash
# Run tests with coverage enabled
swift test --enable-code-coverage

# View the coverage JSON path
swift test --show-codecov-path

# Generate a text report using llvm-cov
BIN_PATH=$(swift build --show-bin-path)
xcrun llvm-cov report \
  "${BIN_PATH}/BitekeyPackageTests.xctest/Contents/MacOS/BitekeyPackageTests" \
  -instr-profile="${BIN_PATH}/codecov/default.profdata" \
  -ignore-filename-regex='.build|Tests'
```

### Setting Up Git Hooks

Run this once per clone to enable the local checks.

```bash
make hooks   # same as ./scripts/setup-hooks
```

The hooks check commit messages, signatures, sign-off, and secrets. On macOS,
they also run the Swift format and lint checks, dependency audit, static scan,
build, tests, and search benchmark. The Makefile pins the required SwiftFormat
and SwiftLint versions.

## Features

- **Global shortcuts** open app search with `Cmd+Space` and clipboard history
  with `Opt+Space` by default. Choose a preset for each mode under
  **Global Shortcuts** in the Bitekey menu. The check mark shows the active
  shortcut. If macOS rejects a choice, Bitekey keeps the current shortcut.
- **Menu bar**: Open either mode, retry global shortcuts, or quit Bitekey
- **Clipboard history** keeps plain text and PNG or TIFF images. Bitekey
  checks for copies about every 200 ms while capture is enabled. If several
  copies replace each other before a check, only the latest can be captured.
- **Liquid Glass panel**: The launcher is a glass panel that opens on the screen
  under the pointer. It does not take focus from the app that will receive a
  paste.
- **Escape Key**: Press `Esc` to dismiss the launcher
- **No Dock Icon**: Runs as a background application (LSUIElement style)

## Project Structure

- `main.swift` - App entry point
- `AppDelegate.swift` - Application lifecycle management
- `HotkeyManager.swift` - Global shortcut registration and preferences
- `Models/` - Observable launcher state: `LauncherModel`, `AppSearchModel`,
  `ClipboardModel`
- `Shell/` - `LauncherPanel` (non-activating panel), `LauncherController` (show,
  hide, position), `CopyClipShortcut`
- `UI/` - SwiftUI views (`LauncherView`, `SearchBar`, `ResultsList`,
  `ClipPreviewPane`, `FooterBar`), `DesignTokens`, icon and image caches
- `ApplicationIndexer.swift`, `SearchService.swift`, `ClipboardManager.swift`,
  `ClipboardReplay.swift` - Search and clipboard services
- `Protocols/`, `System/` - Interfaces for the system and their production code

## Contributing

Issues are welcome. Only project collaborators can open pull requests. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Do not report security problems in public issues. See
[SECURITY.md](SECURITY.md) for the private reporting path.

## License

Bitekey is released under the [MIT License](LICENSE).
