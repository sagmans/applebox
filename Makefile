.PHONY: build test bundle run stop status install uninstall clean zip dmg dist tag release

APP_NAME := AppleBox
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
LOG_DIR := $(HOME)/Library/Logs/$(APP_NAME)
DIST_DIR := $(BUILD_DIR)/dist

# Extract version from Info.plist (can override: make release VERSION=1.0.0)
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
ZIP_NAME := $(APP_NAME)-v$(VERSION)-macOS.zip
DMG_NAME := $(APP_NAME)-v$(VERSION)-macOS.dmg

# --- Development ---

build:
	@swift build -c release

test:
	@swift test

bundle: build
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@echo "Bundle: $(APP_BUNDLE)"

run: stop bundle
	@mkdir -p "$(LOG_DIR)"
	@open "$(APP_BUNDLE)"
	@echo "Started $(APP_NAME)"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null && echo "Stopped $(APP_NAME)" || true

status:
	@pgrep -x $(APP_NAME) >/dev/null && echo "$(APP_NAME) running (PID: $$(pgrep -x $(APP_NAME)))" || echo "$(APP_NAME) not running"

logs:
	@log stream --style compact --predicate 'subsystem == "com.assagman.applebox"' 2>/dev/null || echo "No logs yet"

# --- Install ---

install: bundle
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"

uninstall: stop
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@rm -rf "$(LOG_DIR)"
	@rm -rf "$(HOME)/Library/Caches/$(APP_NAME)"
	@rm -rf "$(HOME)/Library/Application Support/$(APP_NAME)"
	@echo "Uninstalled"

# --- Packaging ---

zip: bundle
	@mkdir -p "$(DIST_DIR)"
	@cd "$(BUILD_DIR)" && zip -r "dist/$(ZIP_NAME)" "$(APP_NAME).app"
	@echo "Created: $(DIST_DIR)/$(ZIP_NAME)"

dmg: bundle
	@mkdir -p "$(DIST_DIR)"
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@mkdir -p "$(BUILD_DIR)/dmg-staging"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg-staging/"
	@ln -sf /Applications "$(BUILD_DIR)/dmg-staging/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(BUILD_DIR)/dmg-staging" \
		-ov -format UDZO "$(DIST_DIR)/$(DMG_NAME)"
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@echo "Created: $(DIST_DIR)/$(DMG_NAME)"

dist: zip dmg
	@echo "Distribution packages ready in $(DIST_DIR)/"
	@ls -lh "$(DIST_DIR)/"

# --- Release ---

tag:
	@git tag -s -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "Created tag: v$(VERSION)"

tag-push: tag
	@git push origin "v$(VERSION)"
	@echo "Pushed tag: v$(VERSION)"

# GitHub release (requires: gh cli, NOTES file or NOTES env var)
# Usage: make release NOTES="Release notes here"
#    or: make release NOTES_FILE=RELEASE_NOTES.md
release: dist tag-push
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
		echo "Error: Provide NOTES='...' or NOTES_FILE=path"; \
		exit 1; \
	fi
	@echo "Released: https://github.com/assagman/applebox/releases/tag/v$(VERSION)"

# --- Clean ---

clean: stop
	@swift package clean 2>/dev/null || true
	@rm -rf .build
	@rm -rf .swiftpm
	@rm -rf Package.resolved
	@rm -rf *.xcodeproj
	@rm -rf .DS_Store
	@echo "Cleaned"
