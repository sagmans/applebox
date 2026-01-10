# AppleBox Testing Guide

This document provides a comprehensive guide to the testing architecture, patterns, and practices used in the AppleBox project.

## Table of Contents

- [Overview](#overview)
- [Directory Structure](#directory-structure)
- [Running Tests](#running-tests)
- [Test Categories](#test-categories)
- [Dependency Injection](#dependency-injection)
- [Writing New Unit Tests](#writing-new-unit-tests)
- [Writing New Mocks](#writing-new-mocks)
- [Snapshot Testing](#snapshot-testing)
- [CI/CD Pipeline](#cicd-pipeline)
- [Pre-Commit Hooks](#pre-commit-hooks)
- [Code Coverage](#code-coverage)

---

## Overview

AppleBox uses a comprehensive testing strategy that includes:

- **Unit Tests** - Testing individual components in isolation
- **Integration Tests** - Testing component interactions end-to-end
- **UI Tests** - Testing window behavior and keyboard handling
- **Snapshot Tests** - Catching visual regressions
- **Accessibility Tests** - Ensuring the UI is accessible

All tests are built on top of XCTest and use dependency injection to enable thorough testing without requiring actual system interactions.

---

## Directory Structure

```
AppleBox/
├── Sources/AppleBox/
│   ├── Protocols/           # Dependency abstraction protocols
│   │   ├── FileSystemProtocol.swift
│   │   ├── PasteboardProtocol.swift
│   │   ├── WorkspaceProtocol.swift
│   │   └── EventSourceProtocol.swift
│   ├── System/              # Production implementations
│   │   ├── SystemFileManager.swift
│   │   ├── SystemPasteboard.swift
│   │   ├── SystemWorkspace.swift
│   │   └── SystemEventSource.swift
│   └── ...                  # Core application files
│
├── Tests/AppleBoxTests/
│   ├── Mocks/               # Mock implementations for testing
│   │   ├── MockFileSystem.swift
│   │   ├── MockPasteboard.swift
│   │   ├── MockWorkspace.swift
│   │   └── MockEventSource.swift
│   ├── __Snapshots__/       # Snapshot reference images
│   │   └── SnapshotTests/   # Per-test-class snapshots
│   ├── SearchServiceTests.swift
│   ├── ApplicationIndexerTests.swift
│   ├── ClipboardManagerTests.swift
│   ├── WindowManagerTests.swift
│   ├── SearchModeSwitchingTests.swift
│   ├── SearchFlowIntegrationTests.swift
│   ├── ClipboardFlowIntegrationTests.swift
│   ├── SnapshotTests.swift
│   └── AccessibilityTests.swift
│
├── .githooks/
│   └── pre-commit           # Pre-commit test hook
│
├── .github/workflows/
│   └── test.yml             # GitHub Actions CI pipeline
│
└── scripts/
    ├── setup-hooks.sh       # Git hooks configuration
    ├── coverage-report.sh   # Local coverage reporting
    └── coverage-badge.py    # Coverage badge generation
```

---

## Running Tests

### Run All Tests

```bash
swift test
```

### Run Tests with Verbose Output

```bash
swift test -v
```

### Run a Specific Test Class

```bash
swift test --filter SearchServiceTests
```

### Run a Specific Test Method

```bash
swift test --filter SearchServiceTests.testExactMatchScoresHighest
```

### Run Tests with Code Coverage

```bash
swift test --enable-code-coverage
```

### Build Before Testing (Recommended)

Running `swift build` before `swift test` provides faster feedback on compilation errors:

```bash
swift build && swift test
```

---

## Test Categories

### Unit Tests

Unit tests verify individual components work correctly in isolation using mock dependencies.

| Test File | Component | What It Tests |
|-----------|-----------|---------------|
| `SearchServiceTests.swift` | `SearchService` | Fuzzy matching algorithm, scoring, result ordering |
| `ApplicationIndexerTests.swift` | `ApplicationIndexer` | Directory scanning, .app detection, deduplication |
| `ClipboardManagerTests.swift` | `ClipboardManager` | Clipboard monitoring, history limits, persistence |

### Integration Tests

Integration tests verify multiple components work together correctly.

| Test File | Components | What It Tests |
|-----------|------------|---------------|
| `SearchFlowIntegrationTests.swift` | FileSystem + ApplicationIndexer + SearchService | End-to-end search flow |
| `ClipboardFlowIntegrationTests.swift` | Pasteboard + ClipboardManager + FileSystem | Clipboard capture and retrieval |

### UI Tests

UI tests verify window behavior and user interaction handling.

| Test File | Component | What It Tests |
|-----------|-----------|---------------|
| `WindowManagerTests.swift` | `WindowManager` | Show/hide, keyboard handling, app launch |
| `SearchModeSwitchingTests.swift` | `WindowManager` | Mode switching between apps and clipboard |

### Snapshot Tests

Snapshot tests capture visual state and detect regressions.

| Test File | What It Captures |
|-----------|------------------|
| `SnapshotTests.swift` | Empty state, search results, clipboard mode, row selection |

### Accessibility Tests

Accessibility tests ensure the UI works with VoiceOver and keyboard navigation.

| Test File | What It Tests |
|-----------|---------------|
| `AccessibilityTests.swift` | Labels, identifiers, keyboard navigation, VoiceOver compatibility |

---

## Dependency Injection

AppleBox uses protocol-based dependency injection to enable testing without system interactions.

### Protocol Pattern

Each external dependency has:
1. **A Protocol** defining the interface (in `Sources/AppleBox/Protocols/`)
2. **A System Implementation** using real system APIs (in `Sources/AppleBox/System/`)
3. **A Mock Implementation** for testing (in `Tests/AppleBoxTests/Mocks/`)

### Example: FileSystemProtocol

```swift
// Protocol (Sources/AppleBox/Protocols/FileSystemProtocol.swift)
protocol FileSystemProtocol {
    var homeDirectoryForCurrentUser: URL { get }
    func fileExists(atPath path: String) -> Bool
    func contentsOfDirectory(at url: URL, ...) throws -> [URL]
    // ... other methods
}

// System Implementation (Sources/AppleBox/System/SystemFileManager.swift)
final class SystemFileManager: FileSystemProtocol {
    private let fileManager: FileManager
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    var homeDirectoryForCurrentUser: URL {
        fileManager.homeDirectoryForCurrentUser
    }
    // ... implementation using FileManager
}

// Mock Implementation (Tests/AppleBoxTests/Mocks/MockFileSystem.swift)
final class MockFileSystem: FileSystemProtocol {
    var mockHomeDirectory: URL = URL(fileURLWithPath: "/Users/testuser")
    var existingFiles: [String: Bool] = [:]
    var directoryContents: [URL: [URL]] = [:]
    
    // Track invocations for verification
    var fileExistsAtPathCalls: [String] = []
    
    // ... implementation returning configurable values
}
```

### Injecting Dependencies

Components accept dependencies via initializer with default production implementations:

```swift
class ApplicationIndexer {
    private let fileSystem: FileSystemProtocol
    
    // Default parameter for production use
    init(fileSystem: FileSystemProtocol = SystemFileManager()) {
        self.fileSystem = fileSystem
    }
}

// In tests:
let mockFileSystem = MockFileSystem()
let indexer = ApplicationIndexer(fileSystem: mockFileSystem)
```

---

## Writing New Unit Tests

### 1. Create the Test File

Create a new file in `Tests/AppleBoxTests/` following the naming convention `{Component}Tests.swift`:

```swift
import XCTest
@testable import AppleBox

final class MyComponentTests: XCTestCase {
    // Test setup
}
```

### 2. Set Up Mocks

Use `setUp()` to create fresh mocks for each test:

```swift
private var mockFileSystem: MockFileSystem!
private var component: MyComponent!

override func setUp() {
    super.setUp()
    mockFileSystem = MockFileSystem()
    component = MyComponent(fileSystem: mockFileSystem)
}

override func tearDown() {
    mockFileSystem = nil
    component = nil
    super.tearDown()
}
```

### 3. Configure Mock State

Set up the mock to return specific values for your test scenario:

```swift
func testFindsApplications() {
    // Configure mock
    let appsDir = URL(fileURLWithPath: "/Applications")
    let safari = appsDir.appendingPathComponent("Safari.app")
    mockFileSystem.addDirectory(at: appsDir, contents: [safari])
    mockFileSystem.existingFiles[safari.path] = true
    
    // Execute
    let result = component.scan()
    
    // Verify
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.name, "Safari")
}
```

### 4. Verify Mock Invocations

Check that the component called the expected methods:

```swift
func testChecksFileExistence() {
    component.checkPath("/some/path")
    
    XCTAssertTrue(mockFileSystem.fileExistsAtPathCalls.contains("/some/path"))
}
```

### 5. Test Edge Cases

Always include tests for:
- Empty inputs
- Missing or invalid data
- Error conditions
- Boundary conditions

---

## Writing New Mocks

### 1. Create the Mock File

Create a new file in `Tests/AppleBoxTests/Mocks/` named `Mock{Component}.swift`:

```swift
import Foundation
@testable import AppleBox

final class MockNewService: NewServiceProtocol {
    // Implementation
}
```

### 2. Add Configurable Properties

Allow tests to set expected return values:

```swift
/// Configurable return value for getData()
var mockData: Data?

/// Error to throw from getData() if set
var getDataError: Error?

func getData() throws -> Data? {
    if let error = getDataError {
        throw error
    }
    return mockData
}
```

### 3. Add Invocation Tracking

Track method calls for verification:

```swift
/// Tracks all getData() calls
var getDataCalls: Int = 0

func getData() throws -> Data? {
    getDataCalls += 1
    // ... rest of implementation
}
```

### 4. Add Helper Methods

Provide convenient methods for common operations:

```swift
/// Clears all recorded invocations
func resetInvocations() {
    getDataCalls = 0
    // ... reset other tracking
}

/// Simulates external change
func simulateChange(data: Data) {
    mockData = data
    // ... update state
}
```

---

## Snapshot Testing

AppleBox uses [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) for visual regression testing.

### How It Works

1. First run: Snapshots are recorded as reference images
2. Subsequent runs: Current output is compared against references
3. Test fails if the visual output differs

### Writing Snapshot Tests

```swift
import XCTest
import SnapshotTesting
@testable import AppleBox

final class SnapshotTests: XCTestCase {
    func testEmptyState() {
        // Set up component
        let windowManager = createWindowManager()
        windowManager.show()
        
        // Get the view to snapshot
        guard let contentView = windowManager.getContentView() else {
            XCTFail("No content view")
            return
        }
        
        // Ensure layout is complete
        contentView.layoutSubtreeIfNeeded()
        
        // Assert snapshot matches reference
        assertSnapshot(of: contentView, as: .image)
    }
}
```

### Snapshot File Location

Reference images are stored in:
```
Tests/AppleBoxTests/__Snapshots__/{TestClassName}/{testMethodName}.1.png
```

### Updating Snapshots

To update reference images when intentional changes are made:

1. Delete the existing snapshot file
2. Run the test (records new reference)
3. Verify the new snapshot looks correct
4. Commit the new snapshot

---

## CI/CD Pipeline

AppleBox uses GitHub Actions for continuous integration.

### Workflow File

The CI pipeline is defined in `.github/workflows/test.yml`:

```yaml
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: swift build -v
      - run: swift test -v --enable-code-coverage
      # ... coverage reporting
```

### What CI Checks

- **Build**: Verifies the project compiles without errors
- **Tests**: Runs all test suites and fails if any test fails
- **Coverage**: Generates code coverage reports

### CI Status

Check the CI status badge in README.md or view workflow runs at:
`https://github.com/{owner}/{repo}/actions`

---

## Pre-Commit Hooks

Pre-commit hooks run tests automatically before each commit, preventing broken code from being committed.

### Setting Up Hooks

Run the setup script once after cloning:

```bash
./scripts/setup-hooks.sh
```

This configures git to use hooks in the `.githooks/` directory.

### What the Hook Does

1. **Build Check**: Runs `swift build` to catch compilation errors
2. **Test Check**: Runs `swift test` to verify all tests pass

If either check fails, the commit is blocked.

### Bypassing Hooks (Not Recommended)

In rare cases, you can skip the hook:

```bash
git commit --no-verify
```

### Disabling Hooks

To remove the hook configuration:

```bash
git config --unset core.hooksPath
```

---

## Code Coverage

### Viewing Coverage Locally

Use the coverage script for easy local viewing:

```bash
# Per-file coverage report
./scripts/coverage-report.sh

# Summary only
./scripts/coverage-report.sh --summary

# Interactive HTML report (opens in browser)
./scripts/coverage-report.sh --html

# Raw JSON data
./scripts/coverage-report.sh --json
```

### Manual Coverage Commands

```bash
# Run tests with coverage
swift test --enable-code-coverage

# Get coverage JSON path
swift test --show-codecov-path

# Generate text report
BIN_PATH=$(swift build --show-bin-path)
xcrun llvm-cov report \
  "${BIN_PATH}/AppleBoxPackageTests.xctest/Contents/MacOS/AppleBoxPackageTests" \
  -instr-profile="${BIN_PATH}/codecov/default.profdata" \
  -ignore-filename-regex='.build|Tests'
```

### Coverage in CI

The CI pipeline automatically:
1. Runs tests with coverage enabled
2. Generates a coverage report
3. Creates a coverage badge artifact
4. Displays coverage percentage in the workflow summary

### Coverage Goals

While there's no enforced minimum, aim for:
- **80%+** coverage for core business logic (SearchService, ApplicationIndexer, ClipboardManager)
- **60%+** overall line coverage
- Focus on testing important code paths over hitting percentage targets

---

## Best Practices

### General

- Run `swift build` before `swift test` for faster feedback
- Use descriptive test method names: `test{Scenario}_{ExpectedBehavior}`
- Keep tests focused - one assertion concept per test
- Clean up in `tearDown()` to prevent test pollution

### Mocks

- Create fresh mocks in each test's `setUp()`
- Use helper methods to reduce mock configuration boilerplate
- Track invocations only when you need to verify calls

### Async/Timer-Based Tests

Some tests involve timers (e.g., ClipboardManager's polling). For these:

```swift
// Wait for timer to fire
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
```

Consider adding direct access methods for faster unit testing when appropriate.

### Snapshot Tests

- Use `layoutSubtreeIfNeeded()` before capturing snapshots
- Keep snapshot sizes reasonable (the default window size is fine)
- Review snapshot changes carefully before committing

---

## Troubleshooting

### Tests Fail with "No such module 'AppleBox'"

Run `swift build` first to compile the main module:

```bash
swift build && swift test
```

### Snapshot Tests Fail on First Run

This is expected! The first run records the reference images. Run again to verify they pass.

### Timer-Based Tests Are Slow

ClipboardManager tests use `RunLoop.current.run(until:)` to wait for timers. This adds ~0.5 seconds per clipboard change simulation. This is intentional for realistic testing.

### Pre-Commit Hook Not Running

Ensure hooks are set up:

```bash
./scripts/setup-hooks.sh
```

Check git config:

```bash
git config core.hooksPath
# Should output: .githooks
```
