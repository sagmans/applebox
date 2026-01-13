.PHONY: build bundle run stop status install uninstall clean

APP_NAME := AppleBox
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications
LOG_DIR := $(HOME)/Library/Logs/$(APP_NAME)

# --- Development ---

build:
	@swift build -c release

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

# --- Clean ---

clean: stop
	@rm -rf .build
	@echo "Cleaned"
