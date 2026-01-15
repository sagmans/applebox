# AppleBox Release Guide

## Overview

This document outlines the complete release process for AppleBox.

```
┌─────────────────────────────────────────────────────────────────┐
│  Release Pipeline                                               │
├─────────────────────────────────────────────────────────────────┤
│  1. Pre-flight    →  Verify clean state, update version        │
│  2. Test          →  Run full test suite                        │
│  3. Build         →  Create release binary and .app bundle     │
│  4. Package       →  Create .zip and .dmg                       │
│  5. Tag           →  Create signed git tag                      │
│  6. Release       →  Push tag, create GitHub release            │
│  7. Verify        →  Confirm release artifacts                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Pre-flight Checks

### 1.1 Verify Clean Working Tree

```bash
git status
```

Expected output:
```
On branch main
nothing to commit, working tree clean
```

If there are uncommitted changes, commit or stash them first.

### 1.2 Pull Latest Changes

```bash
git pull origin main
```

### 1.3 Determine Version Number

Check current version:
```bash
/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist
```

### 1.4 Update Version (if needed)

Edit `Resources/Info.plist`:

| Key | Description | Example |
|-----|-------------|---------|
| `CFBundleVersion` | Build version (semver) | `1.1.0` |
| `CFBundleShortVersionString` | Display version | `1.1` |

```bash
# Using PlistBuddy
/usr/libexec/PlistBuddy -c "Set CFBundleVersion 1.1.0" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString 1.1" Resources/Info.plist
```

Commit version bump:
```bash
git add Resources/Info.plist
git commit -s -m "chore: bump version to 1.1.0"
git push origin main
```

---

## 2. Run Tests

### 2.1 Full Test Suite

```bash
make test
```

Or directly:
```bash
swift test
```

### 2.2 Verify All Tests Pass

Expected: `0 failures`

```
Test Suite 'All tests' passed
Executed 108 tests, with 0 failures
```

**Do not proceed if tests fail.**

---

## 3. Build Release

### 3.1 Clean Build

```bash
make clean
make build
```

### 3.2 Create App Bundle

```bash
make bundle
```

Verify bundle exists:
```bash
ls -la .build/release/AppleBox.app/Contents/
```

Expected structure:
```
AppleBox.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── AppleBox
│   └── Resources/
```

### 3.3 Smoke Test

```bash
make run
```

Manual verification:
- [ ] App launches without crash
- [ ] `Cmd+Space` opens app search
- [ ] `Opt+Space` opens clipboard history
- [ ] `Esc` closes window
- [ ] Keyboard navigation works

Stop the app:
```bash
make stop
```

---

## 4. Create Distribution Packages

### 4.1 Create Both .zip and .dmg

```bash
make dist
```

This creates:
```
.build/release/dist/
├── AppleBox-v1.1.0-macOS.zip
└── AppleBox-v1.1.0-macOS.dmg
```

### 4.2 Individual Packages (optional)

```bash
# ZIP only
make zip

# DMG only
make dmg
```

### 4.3 Verify Packages

```bash
ls -lh .build/release/dist/
```

Expected sizes:
| Package | Approximate Size |
|---------|------------------|
| .zip | ~160 KB |
| .dmg | ~200 KB |

### 4.4 Test DMG Installation

```bash
# Mount DMG
hdiutil attach .build/release/dist/AppleBox-v1.1.0-macOS.dmg

# Verify contents
ls -la /Volumes/AppleBox/

# Expected:
# AppleBox.app
# Applications -> /Applications

# Unmount
hdiutil detach /Volumes/AppleBox
```

---

## 5. Create Git Tag

### 5.1 Create Signed Tag

```bash
make tag
```

Or manually:
```bash
git tag -s -a v1.1.0 -m "Release v1.1.0"
```

### 5.2 Verify Tag

```bash
git tag -l --sort=-v:refname | head -5
git show v1.1.0
```

### 5.3 Push Tag

```bash
git push origin v1.1.0
```

Or use combined target:
```bash
make tag-push
```

---

## 6. Create GitHub Release

### 6.1 Prepare Release Notes

Create a release notes file or use inline notes.

**Option A: Inline Notes**
```bash
make release VERSION=1.1.0 NOTES="## What's New

- Feature: Added XYZ
- Fix: Resolved ABC issue
- Performance: Improved search speed"
```

**Option B: Notes File**

Create `RELEASE_NOTES.md`:
```markdown
## What's New

### Features
- Added XYZ feature

### Bug Fixes  
- Fixed ABC issue

### Performance
- Improved search speed by 2x
```

Then run:
```bash
make release VERSION=1.1.0 NOTES_FILE=RELEASE_NOTES.md
```

### 6.2 Manual GitHub Release (alternative)

```bash
gh release create v1.1.0 \
  --title "AppleBox v1.1.0" \
  --notes-file RELEASE_NOTES.md \
  .build/release/dist/AppleBox-v1.1.0-macOS.zip \
  .build/release/dist/AppleBox-v1.1.0-macOS.dmg
```

---

## 7. Post-Release Verification

### 7.1 Verify GitHub Release

```bash
gh release view v1.1.0
```

Or visit: `https://github.com/assagman/applebox/releases/tag/v1.1.0`

### 7.2 Verify Assets

```bash
gh release view v1.1.0 --json assets --jq '.assets[].name'
```

Expected:
```
AppleBox-v1.1.0-macOS.zip
AppleBox-v1.1.0-macOS.dmg
```

### 7.3 Download and Test Release Artifact

```bash
# Download from GitHub
gh release download v1.1.0 --pattern "*.dmg" --dir /tmp

# Mount and verify
hdiutil attach /tmp/AppleBox-v1.1.0-macOS.dmg
ls /Volumes/AppleBox/
hdiutil detach /Volumes/AppleBox
```

---

## Quick Release (One-Liner)

For a standard release after version bump:

```bash
make clean && make test && make release VERSION=1.1.0 NOTES="Bug fixes and improvements"
```

---

## Troubleshooting

### Tag Already Exists

```bash
# Delete local tag
git tag -d v1.1.0

# Delete remote tag (if pushed)
git push origin --delete v1.1.0
```

### Release Already Exists

```bash
# Delete GitHub release
gh release delete v1.1.0 --yes

# Then delete tag and recreate
```

### DMG Creation Fails

```bash
# Check if volume is already mounted
hdiutil info | grep AppleBox

# Detach if mounted
hdiutil detach /Volumes/AppleBox -force
```

### Build Fails After Clean

```bash
# Reset Swift package
swift package reset
swift package resolve
make build
```

---

## Release Checklist

```
[ ] Working tree clean
[ ] Version updated in Info.plist
[ ] All tests pass
[ ] Release build succeeds
[ ] App smoke test passes
[ ] .zip created
[ ] .dmg created
[ ] Git tag created and pushed
[ ] GitHub release created
[ ] Release assets uploaded
[ ] Download and verify artifacts
```

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| 1.0.0 | 2026-01-15 | Initial release |

---

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `swift` | Build | Xcode |
| `git` | Version control | Xcode CLI |
| `gh` | GitHub CLI | `brew install gh` |
| `hdiutil` | DMG creation | macOS built-in |
| `PlistBuddy` | Plist editing | macOS built-in |
