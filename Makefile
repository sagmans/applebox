.PHONY: build test python-policy format format-check swiftformat-version swiftlint-version lint hooks bundle run stop status install uninstall clean \
        audit-swift-dependencies swift-sast benchmark-search \
        sign verify-sign check-adhoc notarize check-notarize staple \
        notary-check zip dmg dist tag tag-push release ship \
        preflight version-bump help

# ==============================================================================
# Configuration
# ==============================================================================

APP_NAME := AppleBox
BUNDLE_ID := com.assagman.applebox
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
LOCAL_INSTALLER := scripts/install-local.swift
LOCAL_SIGNING_IDENTITY ?= -
LOG_DIR := $(HOME)/Library/Logs/$(APP_NAME)
DIST_DIR := $(BUILD_DIR)/dist

# Extract version from Info.plist (can override: make release VERSION=1.0.0)
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist 2>/dev/null || echo "0.0.0")
ZIP_NAME := $(APP_NAME)-v$(VERSION)-macOS.zip
DMG_NAME := $(APP_NAME)-v$(VERSION)-macOS.dmg

# Code signing configuration
DEVELOPER_ID := Developer ID Application: Ahmet Sercan Sagman (6C96BU4M82)
TEAM_ID := 6C96BU4M82
NOTARIZE_PROFILE := AppleBox-Notarize
ENTITLEMENTS := Resources/AppleBox.entitlements

# Exact SwiftFormat release the tree is formatted with. Each release can add or
# change rules, so another local version rewrites files or fails format-check
# on clean code. Bump this value, --minversion in .swiftformat, and the
# reformatted tree in one commit.
SWIFTFORMAT_VERSION := 0.64.1
SWIFTFORMAT_RELEASE_URL := https://github.com/nicklockwood/SwiftFormat/releases/tag/$(SWIFTFORMAT_VERSION)

# Exact SwiftLint release the tree is linted with. Each release can add or
# change rules, so another local version fails lint on clean code or misses
# findings. Bump this value, swiftlint_version in .swiftlint.yml, and any lint
# fixes in one commit.
SWIFTLINT_VERSION := 0.65.1
SWIFTLINT_RELEASE_URL := https://github.com/realm/SwiftLint/releases/tag/$(SWIFTLINT_VERSION)
SWIFT_STYLE_PATHS := Sources Tests scripts/benchmark-search.swift $(LOCAL_INSTALLER)
SEARCH_BENCHMARK := .build/applebox-search-benchmark
SEARCH_BENCHMARK_SOURCES := scripts/benchmark-search.swift \
	Sources/AppleBox/SearchService.swift Sources/AppleBox/ApplicationIndexer.swift \
	Sources/AppleBox/ApplicationFolderMonitor.swift Sources/AppleBox/LogSubsystem.swift \
	Sources/AppleBox/Protocols/FileSystemProtocol.swift Sources/AppleBox/System/SystemFileManager.swift
SWIFT_SCAN_TIMEOUT := 120

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
NC := \033[0m  # No Color

# ==============================================================================
# Help
# ==============================================================================

help:
	@echo ""
	@echo "$(BLUE)AppleBox Makefile$(NC)"
	@echo "=================="
	@echo ""
	@echo "$(GREEN)Development:$(NC)"
	@echo "  make build        - Build release binary"
	@echo "  make test         - Run test suite"
	@echo "  make format       - Auto-format Sources/ and Tests/ (SwiftFormat)"
	@echo "  make format-check - Fail if formatting is needed (SwiftFormat --lint)"
	@echo "  make lint         - Run SwiftLint"
	@echo "  make hooks        - Enable tracked git hooks (run once per clone)"
	@echo "  make bundle       - Create .app bundle"
	@echo "  make run          - Build, bundle, and run app"
	@echo "  make stop         - Stop running app"
	@echo "  make status       - Check if app is running"
	@echo "  make logs         - Stream app logs"
	@echo ""
	@echo "$(GREEN)Installation:$(NC)"
	@echo "  make install      - Install or update in ~/Applications"
	@echo "  make uninstall    - Move the local bundle to Trash, keeping history"
	@echo ""
	@echo "$(GREEN)Code Signing:$(NC)"
	@echo "  make sign         - Sign app with Developer ID"
	@echo "  make verify-sign  - Verify code signature"
	@echo "  make check-adhoc  - Check for ad-hoc signature (warning)"
	@echo "  make notary-check - $(YELLOW)FULL notarization readiness check$(NC)"
	@echo "  make notarize     - Submit to Apple notarization"
	@echo "  make check-notarize ID=xxx - Check notarization status"
	@echo "  make staple       - Staple notarization ticket"
	@echo ""
	@echo "$(GREEN)Packaging:$(NC)"
	@echo "  make zip          - Create signed .zip"
	@echo "  make dmg          - Create signed .dmg"
	@echo "  make dist         - Create both .zip and .dmg"
	@echo ""
	@echo "$(GREEN)Release:$(NC)"
	@echo "  make preflight    - Run all pre-release checks"
	@echo "  make tag          - Create signed git tag"
	@echo "  make tag-push     - Create and push tag"
	@echo "  make release      - Full release to GitHub"
	@echo "  make ship         - $(YELLOW)FULL PIPELINE$(NC): clean → test → sign → notarize → dist → release"
	@echo ""
	@echo "$(GREEN)Maintenance:$(NC)"
	@echo "  make clean        - Remove all build artifacts"
	@echo "  make version-bump V=x.y.z - Update version in Info.plist"
	@echo ""
	@echo "$(GREEN)Examples:$(NC)"
	@echo "  make ship VERSION=1.2.0 NOTES=\"Bug fixes\""
	@echo "  make release VERSION=1.2.0 NOTES_FILE=CHANGELOG.md"
	@echo "  make check-notarize ID=b9976e01-0b7d-4f0a-9a61-79d65ef0731a"
	@echo ""

# ==============================================================================
# Development
# ==============================================================================

build:
	@echo "$(BLUE)Building $(APP_NAME)...$(NC)"
	@swift build -c release
	@echo "$(GREEN)Build complete$(NC)"

python-policy:
	@bash scripts/check-python-runtime.sh

test: python-policy
	@echo "$(BLUE)Running tests...$(NC)"
	@swift test
	@echo "$(GREEN)All tests passed$(NC)"

audit-swift-dependencies:
	@bash scripts/audit-swift-dependencies.sh

swift-sast:
	@timeout $(SWIFT_SCAN_TIMEOUT) semgrep scan --config .semgrep-swift.yml --metrics=off \
		--disable-version-check --strict --error Sources scripts/benchmark-search.swift

benchmark-search:
	@mkdir -p "$(dir $(SEARCH_BENCHMARK))"
	@swiftc -O $(SEARCH_BENCHMARK_SOURCES) -o "$(SEARCH_BENCHMARK)"
	@"$(SEARCH_BENCHMARK)"

# ==============================================================================
# Code Style
# ==============================================================================

# Runs before format and format-check and fails closed, so the pre-commit hook
# never accepts or rewrites code with a SwiftFormat release other than the pin.
swiftformat-version:
	@installed=$$(swiftformat --version 2>/dev/null || echo "not installed"); \
	if [ "$$installed" != "$(SWIFTFORMAT_VERSION)" ]; then \
		echo "$(RED)SwiftFormat $(SWIFTFORMAT_VERSION) required, found: $$installed$(NC)" >&2; \
		echo "Install it from $(SWIFTFORMAT_RELEASE_URL)" >&2; \
		exit 1; \
	fi

format: swiftformat-version
	@echo "$(BLUE)Formatting Swift sources (SwiftFormat)...$(NC)"
	swiftformat $(SWIFT_STYLE_PATHS)
	@echo "$(GREEN)Formatting complete$(NC)"

format-check: swiftformat-version
	@echo "$(BLUE)Checking formatting (SwiftFormat --lint)...$(NC)"
	@if [ "$$GITHUB_ACTIONS" = "true" ]; then \
		swiftformat $(SWIFT_STYLE_PATHS) --lint --reporter github-actions-log; \
	else \
		swiftformat $(SWIFT_STYLE_PATHS) --lint; \
	fi
	@echo "$(GREEN)Formatting OK$(NC)"

hooks:
	@./scripts/setup-hooks

# Runs before lint and fails closed with an install link, so the pre-commit
# hook never accepts code checked by a SwiftLint release other than the pin.
# The swiftlint_version key in .swiftlint.yml would also fail, but without a
# clear fix, and a missing binary would only show "command not found".
swiftlint-version:
	@installed=$$(swiftlint version 2>/dev/null || echo "not installed"); \
	if [ "$$installed" != "$(SWIFTLINT_VERSION)" ]; then \
		echo "$(RED)SwiftLint $(SWIFTLINT_VERSION) required, found: $$installed$(NC)" >&2; \
		echo "Install it from $(SWIFTLINT_RELEASE_URL)" >&2; \
		exit 1; \
	fi

lint: swiftlint-version
	@echo "$(BLUE)Linting Swift sources (SwiftLint)...$(NC)"
	@REPORTER=xcode; \
	if [ "$$GITHUB_ACTIONS" = "true" ]; then REPORTER=github-actions-logging; fi; \
	swiftlint lint --config .swiftlint.yml --force-exclude --reporter $$REPORTER
	@echo "$(GREEN)Lint OK$(NC)"

bundle: build
	@echo "$(BLUE)Creating app bundle...$(NC)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"
	@# Touch app bundle to refresh icon cache
	@touch "$(APP_BUNDLE)"
	@# Copy entitlements if exists (for reference, not embedded in bundle)
	@if [ -f "$(ENTITLEMENTS)" ]; then \
		cp "$(ENTITLEMENTS)" "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@echo "$(GREEN)Bundle created: $(APP_BUNDLE)$(NC)"

run: stop bundle
	@mkdir -p "$(LOG_DIR)"
	@open "$(APP_BUNDLE)"
	@echo "$(GREEN)Started $(APP_NAME)$(NC)"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null && echo "$(YELLOW)Stopped $(APP_NAME)$(NC)" || true

status:
	@pgrep -x $(APP_NAME) >/dev/null && echo "$(GREEN)$(APP_NAME) running (PID: $$(pgrep -x $(APP_NAME)))$(NC)" || echo "$(YELLOW)$(APP_NAME) not running$(NC)"

logs:
	@log stream --style compact --predicate 'subsystem == "$(BUNDLE_ID)"' 2>/dev/null || echo "No logs yet"

# ==============================================================================
# Installation
# ==============================================================================

install: bundle
	@codesign --force --sign "$(LOCAL_SIGNING_IDENTITY)" "$(APP_BUNDLE)"
	@codesign --verify --strict "$(APP_BUNDLE)"
	@swift "$(LOCAL_INSTALLER)" install "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app" "$(BUNDLE_ID)"

uninstall:
	@swift "$(LOCAL_INSTALLER)" uninstall "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app" "$(BUNDLE_ID)"

# ==============================================================================
# Code Signing & Notarization
# ==============================================================================

# Check if app has ad-hoc signature (common mistake)
check-adhoc:
	@echo "$(BLUE)Checking for ad-hoc signature...$(NC)"
	@if [ -d "$(APP_BUNDLE)" ]; then \
		SIG=$$(codesign -dv "$(APP_BUNDLE)" 2>&1 | grep "Signature=" | cut -d= -f2); \
		if [ "$$SIG" = "adhoc" ]; then \
			echo "$(RED)ERROR: App has ad-hoc signature!$(NC)"; \
			echo "$(RED)This will NOT work for distribution.$(NC)"; \
			echo "$(YELLOW)Run 'make sign' to sign with Developer ID.$(NC)"; \
			exit 1; \
		else \
			echo "$(GREEN)OK: Not ad-hoc signed$(NC)"; \
		fi \
	else \
		echo "$(YELLOW)No bundle found yet$(NC)"; \
	fi

# Check if Developer ID certificate is available
check-cert:
	@echo "$(BLUE)Checking Developer ID certificate...$(NC)"
	@if security find-identity -v -p codesigning | grep -q "$(TEAM_ID)"; then \
		echo "$(GREEN)OK: Developer ID certificate found$(NC)"; \
		security find-identity -v -p codesigning | grep "$(TEAM_ID)"; \
	else \
		echo "$(RED)ERROR: Developer ID certificate not found!$(NC)"; \
		echo "$(YELLOW)Expected: $(DEVELOPER_ID)$(NC)"; \
		echo ""; \
		echo "To fix:"; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Import your Developer ID certificate"; \
		echo "  3. Or download from Apple Developer portal"; \
		exit 1; \
	fi

# Check if notarization credentials are stored
check-notarize-creds:
	@echo "$(BLUE)Checking notarization credentials...$(NC)"
	@if xcrun notarytool store-credentials --help >/dev/null 2>&1; then \
		echo "$(GREEN)OK: notarytool available$(NC)"; \
	else \
		echo "$(RED)ERROR: notarytool not available$(NC)"; \
		exit 1; \
	fi
	@# Note: We can't easily verify stored credentials without attempting to use them

# Sign the app bundle with Developer ID
sign: bundle check-cert
	@echo "$(BLUE)Signing $(APP_BUNDLE)...$(NC)"
	@# Sign the main executable first
	@if [ -f "$(ENTITLEMENTS)" ]; then \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--entitlements "$(ENTITLEMENTS)" \
			--timestamp \
			"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	else \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--timestamp \
			"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	fi
	@# Sign the bundle
	@if [ -f "$(ENTITLEMENTS)" ]; then \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--entitlements "$(ENTITLEMENTS)" \
			--timestamp \
			"$(APP_BUNDLE)"; \
	else \
		codesign --force --options runtime \
			--sign "$(DEVELOPER_ID)" \
			--timestamp \
			"$(APP_BUNDLE)"; \
	fi
	@echo "$(GREEN)Signed: $(APP_BUNDLE)$(NC)"
	@# Verify signature immediately
	@$(MAKE) verify-sign --no-print-directory

# Verify code signature
verify-sign:
	@echo "$(BLUE)Verifying signature...$(NC)"
	@echo ""
	@echo "--- Signature Details ---"
	@codesign -dv --verbose=2 "$(APP_BUNDLE)" 2>&1 | grep -E "(Identifier|Authority|TeamIdentifier|Signature|Runtime)" || true
	@echo ""
	@echo "--- Gatekeeper Check ---"
	@spctl -a -t exec -vv "$(APP_BUNDLE)" 2>&1 && echo "$(GREEN)Gatekeeper: PASSED$(NC)" || echo "$(YELLOW)Gatekeeper: May require notarization$(NC)"
	@echo ""
	@# Check for ad-hoc
	@SIG=$$(codesign -dv "$(APP_BUNDLE)" 2>&1 | grep "Signature=" | cut -d= -f2); \
	if [ "$$SIG" = "adhoc" ]; then \
		echo "$(RED)WARNING: Ad-hoc signature detected!$(NC)"; \
	fi

# Submit to Apple notarization service
notarize: sign
	@echo "$(BLUE)Preparing for notarization...$(NC)"
	@mkdir -p "$(DIST_DIR)"
	@# Create ZIP for submission
	@echo "Creating ZIP for notarization..."
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(DIST_DIR)/$(APP_NAME)-notarize.zip"
	@echo ""
	@echo "$(BLUE)Submitting to Apple notarization service...$(NC)"
	@echo "$(YELLOW)This may take 5-15 minutes...$(NC)"
	@echo ""
	@# Submit and wait
	@xcrun notarytool submit "$(DIST_DIR)/$(APP_NAME)-notarize.zip" \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait \
		--timeout 30m \
		2>&1 | tee "$(DIST_DIR)/notarize.log"
	@# Check result
	@if grep -q "status: Accepted" "$(DIST_DIR)/notarize.log"; then \
		echo ""; \
		echo "$(GREEN)Notarization ACCEPTED!$(NC)"; \
		rm -f "$(DIST_DIR)/$(APP_NAME)-notarize.zip"; \
	else \
		echo ""; \
		echo "$(RED)Notarization may have failed. Check log:$(NC)"; \
		echo "$(DIST_DIR)/notarize.log"; \
		echo ""; \
		echo "To check status manually:"; \
		ID=$$(grep "id:" "$(DIST_DIR)/notarize.log" | head -1 | awk '{print $$2}'); \
		echo "  make check-notarize ID=$$ID"; \
		exit 1; \
	fi

# Check notarization status by submission ID
check-notarize:
	@if [ -z "$(ID)" ]; then \
		echo "$(RED)Usage: make check-notarize ID=<submission-id>$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Checking notarization status...$(NC)"
	@xcrun notarytool info "$(ID)" --keychain-profile "$(NOTARIZE_PROFILE)"
	@echo ""
	@echo "$(BLUE)Fetching detailed log...$(NC)"
	@xcrun notarytool log "$(ID)" --keychain-profile "$(NOTARIZE_PROFILE)" 2>/dev/null || echo "$(YELLOW)Log not available yet$(NC)"

# Staple notarization ticket to app
staple:
	@echo "$(BLUE)Stapling notarization ticket...$(NC)"
	@xcrun stapler staple "$(APP_BUNDLE)"
	@echo "$(GREEN)Stapled: $(APP_BUNDLE)$(NC)"
	@echo ""
	@echo "--- Verifying staple ---"
	@xcrun stapler validate "$(APP_BUNDLE)" && echo "$(GREEN)Staple: VALID$(NC)"

# ==============================================================================
# Notarization Readiness Check (Apple Documentation Compliance)
# https://developer.apple.com/documentation/security/resolving-common-notarization-issues
# ==============================================================================

notary-check: sign
	@echo ""
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  NOTARIZATION READINESS CHECK                                   $(NC)"
	@echo "$(BLUE)  Based on: Apple Developer Documentation                        $(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@PASS=0; FAIL=0; WARN=0; \
	\
	echo "$(BLUE)[1/9] Code Signature Verification (--deep --strict)$(NC)"; \
	if codesign -vvv --deep --strict "$(APP_BUNDLE)" 2>&1; then \
		echo "$(GREEN)  ✓ PASS: Code signature valid$(NC)"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Code signature invalid$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[2/9] Developer ID Certificate$(NC)"; \
	AUTHORITY=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "Authority=Developer ID" | head -1); \
	if [ -n "$$AUTHORITY" ]; then \
		echo "$(GREEN)  ✓ PASS: $$AUTHORITY$(NC)"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Not signed with Developer ID certificate$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[3/9] Team Identifier$(NC)"; \
	TEAM=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2); \
	if [ -n "$$TEAM" ] && [ "$$TEAM" != "not set" ]; then \
		echo "$(GREEN)  ✓ PASS: TeamIdentifier=$$TEAM$(NC)"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: TeamIdentifier not set$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[4/9] Hardened Runtime$(NC)"; \
	FLAGS=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "flags=" | head -1); \
	if echo "$$FLAGS" | grep -q "runtime"; then \
		echo "$(GREEN)  ✓ PASS: Hardened runtime enabled$(NC)"; \
		echo "    $$FLAGS"; \
		PASS=$$((PASS+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Hardened runtime NOT enabled$(NC)"; \
		echo "    $$FLAGS"; \
		echo "$(YELLOW)    Fix: Add --options runtime to codesign$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[5/9] Secure Timestamp$(NC)"; \
	TIMESTAMP=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "Timestamp="); \
	SIGNEDTIME=$$(codesign -dvv "$(APP_BUNDLE)" 2>&1 | grep "Signed Time"); \
	if [ -n "$$TIMESTAMP" ]; then \
		echo "$(GREEN)  ✓ PASS: Secure timestamp present$(NC)"; \
		echo "    $$TIMESTAMP"; \
		PASS=$$((PASS+1)); \
	elif [ -n "$$SIGNEDTIME" ]; then \
		echo "$(RED)  ✗ FAIL: No secure timestamp (only Signed Time found)$(NC)"; \
		echo "$(YELLOW)    Fix: Add --timestamp to codesign$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(RED)  ✗ FAIL: No timestamp found$(NC)"; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[6/9] get-task-allow Entitlement (must NOT be present)$(NC)"; \
	ENTITLEMENTS=$$(codesign -d --entitlements :- "$(APP_BUNDLE)" 2>&1); \
	if echo "$$ENTITLEMENTS" | grep -q "get-task-allow.*true"; then \
		echo "$(RED)  ✗ FAIL: get-task-allow=true found (debug entitlement)$(NC)"; \
		echo "$(YELLOW)    Fix: Remove get-task-allow or set to false$(NC)"; \
		echo "$(YELLOW)    This is injected by Xcode for debug builds$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(GREEN)  ✓ PASS: get-task-allow not present$(NC)"; \
		PASS=$$((PASS+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[7/9] Entitlements Format (must NOT be binary plist)$(NC)"; \
	if echo "$$ENTITLEMENTS" | grep -q "bplist00"; then \
		echo "$(RED)  ✗ FAIL: Binary plist entitlements detected$(NC)"; \
		echo "$(YELLOW)    Fix: Use XML format for entitlements file$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(GREEN)  ✓ PASS: Entitlements are not binary plist$(NC)"; \
		PASS=$$((PASS+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[8/9] Ad-hoc Signature Check$(NC)"; \
	SIG=$$(codesign -dv "$(APP_BUNDLE)" 2>&1 | grep "Signature=" | cut -d= -f2); \
	if [ "$$SIG" = "adhoc" ]; then \
		echo "$(RED)  ✗ FAIL: Ad-hoc signature detected$(NC)"; \
		echo "$(YELLOW)    Fix: Sign with Developer ID certificate$(NC)"; \
		FAIL=$$((FAIL+1)); \
	else \
		echo "$(GREEN)  ✓ PASS: Not ad-hoc signed$(NC)"; \
		PASS=$$((PASS+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)[9/9] Gatekeeper Assessment$(NC)"; \
	SPCTL_OUT=$$(spctl -a -vvv --type exec "$(APP_BUNDLE)" 2>&1); \
	SPCTL_EXIT=$$?; \
	if [ $$SPCTL_EXIT -eq 0 ]; then \
		echo "$(GREEN)  ✓ PASS: Gatekeeper approved$(NC)"; \
		echo "$$SPCTL_OUT" | head -2 | sed 's/^/    /'; \
		PASS=$$((PASS+1)); \
	elif echo "$$SPCTL_OUT" | grep -q "Unnotarized Developer ID"; then \
		echo "$(YELLOW)  ⚠ WARN: Signed but not yet notarized$(NC)"; \
		echo "$$SPCTL_OUT" | head -2 | sed 's/^/    /'; \
		WARN=$$((WARN+1)); \
	else \
		echo "$(RED)  ✗ FAIL: Gatekeeper rejected$(NC)"; \
		echo "$$SPCTL_OUT" | head -3 | sed 's/^/    /'; \
		FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	\
	echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"; \
	echo "$(BLUE)  SUMMARY$(NC)"; \
	echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"; \
	echo ""; \
	echo "  $(GREEN)PASS: $$PASS$(NC)  $(YELLOW)WARN: $$WARN$(NC)  $(RED)FAIL: $$FAIL$(NC)"; \
	echo ""; \
	if [ $$FAIL -eq 0 ]; then \
		if [ $$WARN -eq 0 ]; then \
			echo "$(GREEN)  ✓ READY FOR NOTARIZATION$(NC)"; \
		else \
			echo "$(GREEN)  ✓ READY FOR NOTARIZATION (warnings are expected before notarization)$(NC)"; \
		fi; \
		echo ""; \
		echo "  Next step:"; \
		echo "    make notarize"; \
	else \
		echo "$(RED)  ✗ NOT READY - Fix the failures above$(NC)"; \
		exit 1; \
	fi; \
	echo ""

# ==============================================================================
# Packaging
# ==============================================================================

# Create signed and notarized ZIP
zip: staple
	@echo "$(BLUE)Creating ZIP package...$(NC)"
	@mkdir -p "$(DIST_DIR)"
	@cd "$(BUILD_DIR)" && zip -r -q "dist/$(ZIP_NAME)" "$(APP_NAME).app"
	@echo "$(GREEN)Created: $(DIST_DIR)/$(ZIP_NAME)$(NC)"
	@ls -lh "$(DIST_DIR)/$(ZIP_NAME)"

# Create signed and notarized DMG
dmg: staple
	@echo "$(BLUE)Creating DMG package...$(NC)"
	@mkdir -p "$(DIST_DIR)"
	@# Clean up any existing staging
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@mkdir -p "$(BUILD_DIR)/dmg-staging"
	@# Copy app and create Applications symlink
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg-staging/"
	@ln -sf /Applications "$(BUILD_DIR)/dmg-staging/Applications"
	@# Add volume icon for DMG (shows in Finder when mounted)
	@cp Resources/AppIcon.icns "$(BUILD_DIR)/dmg-staging/.VolumeIcon.icns"
	@# Create DMG
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(BUILD_DIR)/dmg-staging" \
		-ov -format UDZO \
		"$(DIST_DIR)/$(DMG_NAME)" \
		>/dev/null
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@# Notarize the DMG itself (optional but recommended)
	@echo "$(BLUE)Notarizing DMG...$(NC)"
	@xcrun notarytool submit "$(DIST_DIR)/$(DMG_NAME)" \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait \
		--timeout 15m \
		>/dev/null 2>&1 && \
		xcrun stapler staple "$(DIST_DIR)/$(DMG_NAME)" >/dev/null 2>&1 || \
		echo "$(YELLOW)DMG notarization skipped (app already notarized)$(NC)"
	@echo "$(GREEN)Created: $(DIST_DIR)/$(DMG_NAME)$(NC)"
	@ls -lh "$(DIST_DIR)/$(DMG_NAME)"

# Create both distribution packages
dist: zip dmg
	@echo ""
	@echo "$(GREEN)Distribution packages ready:$(NC)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@ls -lh "$(DIST_DIR)/"*.zip "$(DIST_DIR)/"*.dmg 2>/dev/null || true
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ==============================================================================
# Release
# ==============================================================================

# Pre-flight checks before release
preflight: check-cert
	@echo ""
	@echo "$(BLUE)Running pre-flight checks...$(NC)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@# Check git status
	@echo "$(BLUE)[1/6] Git status...$(NC)"
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "$(YELLOW)WARNING: Uncommitted changes detected$(NC)"; \
		git status --short; \
	else \
		echo "$(GREEN)OK: Working tree clean$(NC)"; \
	fi
	@echo ""
	@# Check version
	@echo "$(BLUE)[2/6] Version check...$(NC)"
	@echo "Current version: $(VERSION)"
	@if git tag | grep -q "^v$(VERSION)$$"; then \
		echo "$(RED)ERROR: Tag v$(VERSION) already exists!$(NC)"; \
		echo "$(YELLOW)Use: make version-bump V=x.y.z$(NC)"; \
	else \
		echo "$(GREEN)OK: Tag v$(VERSION) available$(NC)"; \
	fi
	@echo ""
	@# Check gh cli
	@echo "$(BLUE)[3/6] GitHub CLI...$(NC)"
	@if command -v gh >/dev/null 2>&1; then \
		echo "$(GREEN)OK: gh CLI available$(NC)"; \
		gh auth status 2>&1 | head -2 || true; \
	else \
		echo "$(RED)ERROR: gh CLI not found$(NC)"; \
		echo "$(YELLOW)Install: brew install gh$(NC)"; \
	fi
	@echo ""
	@# Check signing cert (already done above)
	@echo "$(BLUE)[4/6] Code signing certificate...$(NC)"
	@echo "$(GREEN)OK: Checked above$(NC)"
	@echo ""
	@# Check notarization credentials
	@echo "$(BLUE)[5/6] Notarization credentials...$(NC)"
	@echo "Profile: $(NOTARIZE_PROFILE)"
	@echo "$(YELLOW)Will verify during notarization$(NC)"
	@echo ""
	@# Check Swift
	@echo "$(BLUE)[6/6] Swift toolchain...$(NC)"
	@swift --version | head -1
	@echo "$(GREEN)OK$(NC)"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "$(GREEN)Pre-flight checks complete$(NC)"
	@echo ""

# Create signed git tag
tag:
	@echo "$(BLUE)Creating git tag v$(VERSION)...$(NC)"
	@git tag -s -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "$(GREEN)Created tag: v$(VERSION)$(NC)"

# Push tag to remote
tag-push: tag
	@echo "$(BLUE)Pushing tag to origin...$(NC)"
	@git push origin "v$(VERSION)"
	@echo "$(GREEN)Pushed tag: v$(VERSION)$(NC)"

# Create GitHub release with artifacts
# Usage: make release NOTES="Release notes here"
#    or: make release NOTES_FILE=RELEASE_NOTES.md
release: dist tag-push
	@echo "$(BLUE)Creating GitHub release...$(NC)"
	@if [ -n "$(NOTES_FILE)" ] && [ -f "$(NOTES_FILE)" ]; then \
		gh release create "v$(VERSION)" \
			--title "$(APP_NAME) v$(VERSION)" \
			--notes-file "$(NOTES_FILE)" \
			"$(DIST_DIR)/$(ZIP_NAME)" \
			"$(DIST_DIR)/$(DMG_NAME)"; \
	elif [ -n "$(NOTES)" ]; then \
		gh release create "v$(VERSION)" \
			--title "$(APP_NAME) v$(VERSION)" \
			--notes "$(NOTES)" \
			"$(DIST_DIR)/$(ZIP_NAME)" \
			"$(DIST_DIR)/$(DMG_NAME)"; \
	else \
		echo "$(RED)ERROR: Provide NOTES='...' or NOTES_FILE=path$(NC)"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(GREEN)Released: https://github.com/assagman/applebox/releases/tag/v$(VERSION)$(NC)"

# ==============================================================================
# SHIP - Complete Release Pipeline
# ==============================================================================
# 
# This is the ONE target to rule them all.
# Runs the complete pipeline from clean state to GitHub release.
#
# Usage:
#   make ship VERSION=1.2.0 NOTES="Bug fixes and improvements"
#   make ship VERSION=1.2.0 NOTES_FILE=CHANGELOG.md
#
# Pipeline:
#   1. clean      - Remove all build artifacts
#   2. preflight  - Verify certificates, git status, tools
#   3. test       - Run full test suite
#   4. build      - Compile release binary
#   5. bundle     - Create .app bundle
#   6. sign       - Sign with Developer ID (hardened runtime)
#   7. notarize   - Submit to Apple, wait for approval
#   8. staple     - Attach notarization ticket
#   9. dist       - Create .zip and .dmg packages
#  10. tag-push   - Create and push git tag
#  11. release    - Create GitHub release with artifacts
#
# ==============================================================================

ship: clean preflight test notarize dist tag-push _ship-release
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  SHIP COMPLETE: $(APP_NAME) v$(VERSION)$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "  Release URL: https://github.com/assagman/applebox/releases/tag/v$(VERSION)"
	@echo ""
	@echo "  Artifacts:"
	@ls -lh "$(DIST_DIR)/"*.zip "$(DIST_DIR)/"*.dmg 2>/dev/null | awk '{print "    " $$9 " (" $$5 ")"}'
	@echo ""

# Internal target for ship pipeline (avoids re-running dist)
_ship-release:
	@echo "$(BLUE)Creating GitHub release...$(NC)"
	@if [ -n "$(NOTES_FILE)" ] && [ -f "$(NOTES_FILE)" ]; then \
		gh release create "v$(VERSION)" \
			--title "$(APP_NAME) v$(VERSION)" \
			--notes-file "$(NOTES_FILE)" \
			"$(DIST_DIR)/$(ZIP_NAME)" \
			"$(DIST_DIR)/$(DMG_NAME)"; \
	elif [ -n "$(NOTES)" ]; then \
		gh release create "v$(VERSION)" \
			--title "$(APP_NAME) v$(VERSION)" \
			--notes "$(NOTES)" \
			"$(DIST_DIR)/$(ZIP_NAME)" \
			"$(DIST_DIR)/$(DMG_NAME)"; \
	else \
		echo "$(RED)ERROR: Provide NOTES='...' or NOTES_FILE=path$(NC)"; \
		exit 1; \
	fi

# ==============================================================================
# Utilities
# ==============================================================================

# Bump version in Info.plist
# Usage: make version-bump V=1.2.0
version-bump:
	@if [ -z "$(V)" ]; then \
		echo "$(RED)Usage: make version-bump V=x.y.z$(NC)"; \
		echo "Current version: $(VERSION)"; \
		exit 1; \
	fi
	@echo "$(BLUE)Bumping version to $(V)...$(NC)"
	@/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(V)" Resources/Info.plist
	@/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $(V)" Resources/Info.plist
	@echo "$(GREEN)Version updated to $(V)$(NC)"
	@echo ""
	@echo "Don't forget to commit:"
	@echo "  git add Resources/Info.plist"
	@echo "  git commit -s -m \"chore: bump version to $(V)\""

# ==============================================================================
# Clean
# ==============================================================================

clean: stop
	@echo "$(BLUE)Cleaning build artifacts...$(NC)"
	@swift package clean 2>/dev/null || true
	@rm -rf .build
	@rm -rf .swiftpm
	@rm -rf build
	@rm -rf DerivedData
	@rm -rf *.xcodeproj
	@rm -rf xcuserdata
	@rm -rf *.dSYM *.dSYM.zip
	@find . -name ".DS_Store" -delete 2>/dev/null || true
	@echo "$(GREEN)Cleaned$(NC)"
