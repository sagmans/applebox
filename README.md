# AppleBox - Minimal macOS Launcher

![Coverage](https://img.shields.io/badge/coverage-66%25-green)

AppleBox is a minimal macOS launcher for app search and clipboard history.

## Building

```bash
swift build
```

## Running

```bash
swift run
```

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
  "${BIN_PATH}/AppleBoxPackageTests.xctest/Contents/MacOS/AppleBoxPackageTests" \
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
  with `Opt+Space`.
- **Menu bar**: Open either mode, retry global shortcuts, or quit AppleBox
- **Escape Key**: Press `Esc` to dismiss the launcher
- **Centered Window**: Window appears centered on the active screen
- **No Dock Icon**: Runs as a background application (LSUIElement style)

## Project Structure

- `main.swift` - App entry point
- `AppDelegate.swift` - Application lifecycle management
- `HotkeyManager.swift` - Global hotkey monitoring (Cmd+Space / Opt+Space)
- `WindowManager.swift` - Window display and key handling (Esc/arrows/Enter)

## Development Status

- [x] US-001: Add Test Target to Package.swift
- [x] US-002: Define Protocols for External Dependencies
- [x] US-003: Create Production Implementations of Protocols
- [x] US-004: Refactor ApplicationIndexer for Dependency Injection
- [x] US-005: Refactor ClipboardManager for Dependency Injection
- [x] US-006: Refactor WindowManager for Dependency Injection
- [x] US-007: Create Mock Implementations for Testing
- [x] US-008: Unit Tests for SearchService Fuzzy Matching
- [x] US-009: Unit Tests for ApplicationIndexer
- [x] US-010: Unit Tests for ClipboardManager
- [x] US-011: Integration Tests for Search Flow
- [x] US-012: Integration Tests for Clipboard Flow
- [x] US-013: UI Tests for Window Behavior
- [x] US-014: UI Tests for Search Mode Switching
- [x] US-015: Snapshot Tests for UI Components
- [x] US-016: Accessibility Tests
- [x] US-017: Set Up Pre-Commit Hook for Tests
- [x] US-018: Set Up GitHub Actions CI Pipeline
- [x] US-019: Add Test Coverage Reporting
- [x] US-020: Create Testing Documentation
