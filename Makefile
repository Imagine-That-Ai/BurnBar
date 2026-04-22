# OpenBurnBar — build-from-source installation
#
# Usage:
#   make install          Build Release .app and copy to /Applications
#   make build            Build Release .app only (output in .derived-data)
#   make test             Run all test suites
#   make lint             Run SwiftLint
#   make ci               Run lint + test (full CI check)
#   make uninstall        Remove OpenBurnBar.app from /Applications
#   make clean            Remove build artifacts

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c

SCHEME       := OpenBurnBar
PROJECT      := OpenBurnBar.xcodeproj
CONFIG       := Release
DESTINATION  := platform=macOS
CACHE_DIR    := .spm-cache
DERIVED_DATA := .derived-data
APP_NAME     := OpenBurnBar.app
INSTALL_DIR  := /Applications
DAEMON_PACKAGE := OpenBurnBarDaemon
DAEMON_BIN     := OpenBurnBarDaemon
DAEMON_CORE_DYLIB := libOpenBurnBarCore.dylib

# Built .app location inside DerivedData
APP_BUNDLE = $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(APP_NAME)

.PHONY: preflight build install uninstall clean test lint ci

preflight:
	@command -v xcodebuild >/dev/null 2>&1 || { echo "ERROR: xcodebuild not found. Install Xcode 16+ command line tools first."; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "ERROR: swift not found. Install Xcode 16+ command line tools first."; exit 1; }

build: preflight
	@mkdir -p "$(CACHE_DIR)" "$(DERIVED_DATA)"
	@echo "==> Resolving packages…"
	xcodebuild -resolvePackageDependencies \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-clonedSourcePackagesDirPath $(CACHE_DIR) \
		-derivedDataPath $(DERIVED_DATA) \
		-quiet
	@echo "==> Building daemon…"
	swift build --package-path $(DAEMON_PACKAGE) -c release
	@echo "==> Building $(SCHEME) ($(CONFIG))…"
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination "$(DESTINATION)" \
		-clonedSourcePackagesDirPath $(CACHE_DIR) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build
	@echo "==> Embedding daemon helper…"
	mkdir -p "$(APP_BUNDLE)/Contents/Helpers"
	cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_BIN)" "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"
	cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_CORE_DYLIB)" "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_CORE_DYLIB)"
	chmod +x "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"
	@echo "==> Embedding OpenBurnBarCore framework…"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	OPENBURNBAR_CORE_FRAMEWORK="$(DERIVED_DATA)/Build/Products/$(CONFIG)/PackageFrameworks/OpenBurnBarCore.framework"; \
	if [ ! -d "$$OPENBURNBAR_CORE_FRAMEWORK" ]; then \
		echo "ERROR: Missing OpenBurnBarCore framework at $$OPENBURNBAR_CORE_FRAMEWORK"; \
		exit 1; \
	fi; \
	rm -rf "$(APP_BUNDLE)/Contents/Frameworks/OpenBurnBarCore.framework"; \
	cp -R "$$OPENBURNBAR_CORE_FRAMEWORK" "$(APP_BUNDLE)/Contents/Frameworks/"
	@echo "==> Built: $(APP_BUNDLE)"

install: build
	@echo "==> Installing to $(INSTALL_DIR)/$(APP_NAME)…"
	@# Verify the build produced a valid .app before touching the install dir
	@test -d "$(APP_BUNDLE)" || { echo "ERROR: Build output not found at $(APP_BUNDLE)"; exit 1; }
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
		echo "    Removing existing installation…"; \
		rm -rf "$(INSTALL_DIR)/$(APP_NAME)"; \
	fi
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "==> Done! Launch OpenBurnBar from your menu bar or run:"
	@echo "    open -a OpenBurnBar"

uninstall:
	@echo "==> Removing $(INSTALL_DIR)/$(APP_NAME)…"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "==> Uninstalled."

clean:
	@echo "==> Cleaning build artifacts…"
	rm -rf $(DERIVED_DATA) $(CACHE_DIR)
	@echo "==> Clean."

test: ## Run all test suites (Swift packages + app tests)
	@echo "==> Running Swift package tests…"
	@./scripts/test-openburnbar-swift.sh
	@echo "==> Running app tests…"
	@./scripts/test-openburnbar-app.sh

lint: ## Run SwiftLint
	@command -v swiftlint >/dev/null 2>&1 || { echo "WARNING: swiftlint not found; skipping lint."; exit 0; }
	@swiftlint lint --quiet

ci: lint test ## Full CI check (lint + test)
