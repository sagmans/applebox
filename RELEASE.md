# AppleBox Release Guide

## Overview

This document outlines the complete release process for AppleBox, including code signing and notarization for macOS distribution.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RELEASE PIPELINE                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────┐   ┌──────┐   ┌───────┐   ┌──────┐   ┌───────────┐            │
│   │  Clean  │ → │ Test │ → │ Build │ → │ Sign │ → │ Notarize  │            │
│   └─────────┘   └──────┘   └───────┘   └──────┘   └───────────┘            │
│                                              │           │                   │
│                                              ▼           ▼                   │
│                                         ┌────────┐  ┌─────────┐             │
│                                         │ Staple │←─│ Apple   │             │
│                                         └────────┘  │ Servers │             │
│                                              │      └─────────┘             │
│                                              ▼                               │
│   ┌─────────────────────────────────────────────────────────────┐           │
│   │                    Package (.zip, .dmg)                      │           │
│   └─────────────────────────────────────────────────────────────┘           │
│                                              │                               │
│                                              ▼                               │
│   ┌─────────┐   ┌──────────┐   ┌────────────────────────────────┐           │
│   │ Git Tag │ → │ Push Tag │ → │ GitHub Release + Upload Assets │           │
│   └─────────┘   └──────────┘   └────────────────────────────────┘           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### One-Command Release

```bash
make ship VERSION=1.2.0 NOTES="Bug fixes and performance improvements"
```

This runs the **complete pipeline**:
1. Clean all build artifacts
2. Run pre-flight checks
3. Execute test suite
4. Build release binary
5. Create app bundle
6. Sign with Developer ID
7. Submit to Apple notarization
8. Staple notarization ticket
9. Create .zip and .dmg packages
10. Create git tag and push
11. Create GitHub release with artifacts

---

## Prerequisites

### Required Tools

| Tool | Purpose | Install |
|------|---------|---------|
| Xcode CLI | Swift compiler, codesign | `xcode-select --install` |
| gh | GitHub CLI | `brew install gh` |
| Developer ID cert | Code signing | Apple Developer Portal |

### One-Time Setup

#### 1. Developer ID Certificate

```bash
# Verify certificate is installed
security find-identity -v -p codesigning | grep "Developer ID"
```

Expected output:
```
A4B489BB... "Developer ID Application: Your Name (TEAM_ID)"
```

If missing:
1. Go to [Apple Developer Portal](https://developer.apple.com/account/resources/certificates)
2. Create "Developer ID Application" certificate
3. Download and double-click to install in Keychain

#### 2. Notarization Credentials

Store credentials in Keychain (one-time):

```bash
xcrun notarytool store-credentials "AppleBox-Notarize" \
    --apple-id "your-apple-id@example.com" \
    --team-id "YOUR_TEAM_ID"
```

You'll be prompted for an **App-Specific Password**:
1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign In → Security → App-Specific Passwords
3. Generate password for "AppleBox Notarization"

#### 3. GitHub CLI Authentication

```bash
gh auth login
```

---

## Code Signing Deep Dive

### Why Code Signing?

```
┌─────────────────────────────────────────────────────────────────┐
│  Without Signing              │  With Signing + Notarization    │
├───────────────────────────────┼─────────────────────────────────┤
│  ❌ "damaged and can't be     │  ✅ Opens normally              │
│     opened" error             │                                  │
│  ❌ Blocked by Gatekeeper     │  ✅ Gatekeeper approved          │
│  ❌ Scary security warnings   │  ✅ No warnings                  │
│  ❌ Users must bypass security│  ✅ Professional distribution    │
└───────────────────────────────┴─────────────────────────────────┘
```

### Signing Components

| Component | Purpose |
|-----------|---------|
| Developer ID Certificate | Proves you're a registered Apple developer |
| Hardened Runtime | Security protections required for notarization |
| Timestamp | Proves when app was signed (valid even after cert expires) |
| Entitlements | Declares app's security permissions |

### Ad-Hoc vs Developer ID Signing

```
┌─────────────────────────────────────────────────────────────────┐
│  Ad-Hoc Signature (BAD)        │  Developer ID (GOOD)           │
├────────────────────────────────┼────────────────────────────────┤
│  Signature=adhoc               │  Signature size=9057           │
│  TeamIdentifier=not set        │  TeamIdentifier=6C96BU4M82     │
│  Authority=(none)              │  Authority=Developer ID App... │
│                                │  Authority=Apple Root CA       │
├────────────────────────────────┼────────────────────────────────┤
│  ❌ Cannot notarize            │  ✅ Can notarize                │
│  ❌ Blocked by Gatekeeper      │  ✅ Gatekeeper approved         │
└────────────────────────────────┴────────────────────────────────┘
```

Check your app's signature:
```bash
make check-adhoc
# or manually:
codesign -dv --verbose=2 .build/release/AppleBox.app 2>&1 | grep -E "Signature|Authority|Team"
```

### Entitlements

The `Resources/AppleBox.entitlements` file declares security permissions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

| Entitlement | Purpose |
|-------------|---------|
| `app-sandbox=false` | App runs outside sandbox (required for system-wide hotkeys) |
| `automation.apple-events` | Send Apple Events for window management |

---

## Notarization Deep Dive

### What is Notarization?

Apple scans your app for malware and issues a "ticket" proving it's safe.

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│  Your Mac    │ ───▶ │ Apple Server │ ───▶ │  Your Mac    │
│  Submit .zip │      │  Scan App    │      │  Get Ticket  │
└──────────────┘      │  (~5-15 min) │      │  Staple App  │
                      └──────────────┘      └──────────────┘
```

### Notarization Status

| Status | Meaning |
|--------|---------|
| `In Progress` | Apple is scanning (wait 5-15 min) |
| `Accepted` | ✅ App approved, ready to staple |
| `Invalid` | ❌ Issues found, check log |
| `Rejected` | ❌ Malware or policy violation |

### Check Notarization Status

```bash
# By submission ID
make check-notarize ID=b9976e01-0b7d-4f0a-9a61-79d65ef0731a

# Get detailed log
xcrun notarytool log <ID> --keychain-profile "AppleBox-Notarize"
```

### Common Notarization Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Stuck "In Progress" | Ad-hoc signed | Re-sign with Developer ID |
| Invalid signature | Missing hardened runtime | Add `--options runtime` to codesign |
| Missing timestamp | No `--timestamp` flag | Add `--timestamp` to codesign |
| Credentials error | Wrong keychain profile | Re-store credentials |

---

## Makefile Targets Reference

### Development

```bash
make build          # Build release binary
make test           # Run test suite
make bundle         # Create .app bundle
make run            # Build + run app
make stop           # Stop running app
make logs           # Stream app logs
```

### Code Signing

```bash
make sign           # Sign with Developer ID
make verify-sign    # Verify signature details
make check-adhoc    # Check for ad-hoc signature (error if found)
make check-cert     # Verify Developer ID cert exists
```

### Notarization

```bash
make notarize       # Submit to Apple (includes sign, waits for result)
make check-notarize ID=xxx  # Check submission status
make staple         # Attach notarization ticket
```

### Packaging

```bash
make zip            # Create signed .zip
make dmg            # Create signed .dmg
make dist           # Create both packages
```

### Release

```bash
make preflight      # Run all pre-release checks
make tag            # Create signed git tag
make tag-push       # Create + push tag
make release        # Full release to GitHub
make ship           # COMPLETE PIPELINE (recommended)
```

### Utilities

```bash
make version-bump V=1.2.0   # Update version in Info.plist
make clean                   # Remove all build artifacts
make help                    # Show all targets
```

---

## Step-by-Step Manual Release

If you need more control than `make ship`:

### 1. Pre-flight Checks

```bash
make preflight
```

### 2. Run Tests

```bash
make test
```

### 3. Build and Sign

```bash
make sign
make verify-sign
```

### 4. Notarize

```bash
make notarize
```

If timeout occurs, check status:
```bash
make check-notarize ID=<submission-id>
```

### 5. Staple (if notarize didn't auto-staple)

```bash
make staple
```

### 6. Package

```bash
make dist
```

### 7. Release

```bash
make tag-push
make release NOTES="Your release notes"
```

---

## Troubleshooting

### "damaged and can't be opened"

**Cause**: App not notarized or notarization ticket not stapled.

```bash
# Check if notarized
spctl -a -t exec -vv .build/release/AppleBox.app

# If not, re-notarize
make notarize
make staple
```

### Notarization Stuck "In Progress"

**Cause**: Usually ad-hoc signed app.

```bash
# Check signature
make check-adhoc

# If ad-hoc, re-sign properly
make sign
make notarize
```

### "Developer ID Application" certificate not found

```bash
# List available certificates
security find-identity -v -p codesigning

# If missing, download from Apple Developer Portal
```

### Gatekeeper Blocks App

```bash
# Verify app passes Gatekeeper
spctl -a -t exec -vv .build/release/AppleBox.app

# Should show: "accepted" and "Notarized Developer ID"
```

### Git Tag Already Exists

```bash
# Delete local tag
git tag -d v1.2.0

# Delete remote tag
git push origin --delete v1.2.0
```

### GitHub Release Already Exists

```bash
# Delete release (keeps tag)
gh release delete v1.2.0 --yes

# Or delete both
gh release delete v1.2.0 --yes
git push origin --delete v1.2.0
```

---

## Configuration Reference

### Makefile Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | from Info.plist | Release version |
| `DEVELOPER_ID` | hardcoded | Code signing certificate |
| `TEAM_ID` | `6C96BU4M82` | Apple Team ID |
| `NOTARIZE_PROFILE` | `AppleBox-Notarize` | Keychain profile name |
| `NOTES` | (required) | Release notes inline |
| `NOTES_FILE` | (optional) | Path to release notes file |

### Override Examples

```bash
# Custom version
make ship VERSION=2.0.0 NOTES="Major release"

# Release notes from file
make ship VERSION=1.2.0 NOTES_FILE=CHANGELOG.md

# Just check notarization (different ID)
make check-notarize ID=abc123-def456
```

---

## Release Checklist

```
Pre-Release:
[ ] Working tree clean (git status)
[ ] Version bumped in Info.plist
[ ] CHANGELOG updated (if maintained)
[ ] All tests pass

Signing:
[ ] Developer ID certificate valid
[ ] Notarization credentials stored
[ ] App signed with hardened runtime
[ ] NOT ad-hoc signed

Notarization:
[ ] Submitted to Apple
[ ] Status: Accepted
[ ] Ticket stapled to app

Packaging:
[ ] .zip created
[ ] .dmg created
[ ] Both verified (can open on fresh Mac)

Release:
[ ] Git tag created and pushed
[ ] GitHub release created
[ ] Assets uploaded
[ ] Release URL works

Post-Release:
[ ] Download and test artifact
[ ] App opens without Gatekeeper warning
```

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| 1.1.0 | 2026-01-15 | Code signing & notarization support |
| 1.0.0 | 2026-01-15 | Initial release |
