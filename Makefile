# BurnBar — build-from-source installation
#
# Usage:
#   make install          Build Release .app and copy to /Applications
#   make build            Build Release .app only (output in .derived-data)
#   make uninstall        Remove BurnBar.app from /Applications
#   make clean            Remove build artifacts

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c

SCHEME       := BurnBar
PROJECT      := BurnBar.xcodeproj
CONFIG       := Release
DESTINATION  := platform=macOS
CACHE_DIR    := .spm-cache
DERIVED_DATA := .derived-data
APP_NAME     := BurnBar.app
INSTALL_DIR  := /Applications

# Built .app location inside DerivedData
APP_BUNDLE = $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(APP_NAME)

.PHONY: build install uninstall clean

build:
	@echo "==> Resolving packages…"
	xcodebuild -resolvePackageDependencies \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-clonedSourcePackagesDirPath $(CACHE_DIR) \
		-derivedDataPath $(DERIVED_DATA) \
		-quiet
	@echo "==> Building daemon…"
	swift build --package-path BurnBarDaemon -c release
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
	cp BurnBarDaemon/.build/release/BurnBarDaemon "$(APP_BUNDLE)/Contents/Helpers/BurnBarDaemon"
	chmod +x "$(APP_BUNDLE)/Contents/Helpers/BurnBarDaemon"
	@echo "==> Built: $(APP_BUNDLE)"

install: build
	@echo "==> Installing to $(INSTALL_DIR)/$(APP_NAME)��"
	@# Verify the build produced a valid .app before touching the install dir
	@test -d "$(APP_BUNDLE)" || { echo "ERROR: Build output not found at $(APP_BUNDLE)"; exit 1; }
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
		echo "    Removing existing installation…"; \
		rm -rf "$(INSTALL_DIR)/$(APP_NAME)"; \
	fi
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "==> Done! Launch BurnBar from your menu bar or run:"
	@echo "    open -a BurnBar"

uninstall:
	@echo "==> Removing $(INSTALL_DIR)/$(APP_NAME)…"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "==> Uninstalled."

clean:
	@echo "==> Cleaning build artifacts…"
	rm -rf $(DERIVED_DATA) $(CACHE_DIR)
	@echo "==> Clean."
