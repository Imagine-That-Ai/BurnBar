# OpenBurnBar — build-from-source installation
#
# Usage:
#   make bootstrap        Fresh-clone setup: init submodules + build libsignal FFI
#   make install          Build Release .app and copy to /Applications
#   make build            Build Release .app only (output in .derived-data)
#   make test             Run all test suites
#   make lint             Run SwiftLint
#   make ci               Run lint + test (full CI check)
#   make release-checksums Compute SHA256/SHA512 checksums for built artifacts
#   make sbom              Generate SPDX SBOM for current source tree
#   make uninstall        Remove OpenBurnBar.app from /Applications
#   make clean            Remove build artifacts

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c

SCHEME       := OpenBurnBar
PROJECT      := OpenBurnBar.xcodeproj
CONFIG       := Release
DESTINATION  := platform=macOS,arch=arm64
CACHE_DIR    := .spm-cache
DERIVED_DATA := .derived-data
# Apple Development team for signed local builds. Empty by default so outside
# contributors are never blocked on someone else's team: `build-signed`
# auto-detects an Apple Development identity in the keychain and falls back to
# an ad-hoc-signed build when none exists. Set explicitly to override:
#   OPENBURNBAR_DEVELOPMENT_TEAM=ABCDE12345 make install
OPENBURNBAR_DEVELOPMENT_TEAM ?=
APP_NAME     := OpenBurnBar.app
INSTALL_DIR  := /Applications
DAEMON_PACKAGE := OpenBurnBarDaemon
DAEMON_BIN     := OpenBurnBarDaemon
DAEMON_CORE_DYLIB := libOpenBurnBarCore.dylib

# Built .app location inside DerivedData
APP_BUNDLE = $(DERIVED_DATA)/Build/Products/$(CONFIG)/$(APP_NAME)

.PHONY: bootstrap preflight build build-signed release-mas release-website install uninstall clean test test-full lint debt-check ci release-checksums sbom

preflight:
	@command -v xcodebuild >/dev/null 2>&1 || { echo "ERROR: xcodebuild not found. Install Xcode 16+ command line tools first."; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "ERROR: swift not found. Install Xcode 16+ command line tools first."; exit 1; }

bootstrap: ## Fresh-clone setup: init submodules, preflight Rust/protoc, build the libsignal FFI XCFramework
	@if git submodule status Vendor/libsignal 2>/dev/null | grep -q '^-'; then \
		echo "==> Initializing Vendor/libsignal submodule…"; \
		git submodule update --init --recursive; \
	fi
	@if [ -d Vendor/OpenBurnBarSignalFfi.xcframework ]; then \
		echo "==> OpenBurnBarSignalFfi.xcframework already present — bootstrap complete."; \
	else \
		command -v protoc >/dev/null 2>&1 || { echo "ERROR: protoc not found. Building the vendored libsignal FFI requires it — install with 'brew install protobuf' and re-run 'make bootstrap'."; exit 1; }; \
		{ command -v cargo >/dev/null 2>&1 || [ -x "$$HOME/.cargo/bin/cargo" ]; } || { echo "ERROR: Rust (cargo) not found. Building the vendored libsignal FFI requires it — install via https://rustup.rs and re-run 'make bootstrap'."; exit 1; }; \
		{ command -v rustup >/dev/null 2>&1 || [ -x "$$HOME/.cargo/bin/rustup" ]; } || { echo "ERROR: rustup not found. The libsignal FFI build uses it to add Apple build targets — install via https://rustup.rs and re-run 'make bootstrap'."; exit 1; }; \
		echo "==> Building OpenBurnBarSignalFfi.xcframework (first run can take 20+ minutes)…"; \
		SIGNAL_FFI_BUILD_PROFILE="$${SIGNAL_FFI_BUILD_PROFILE:-release}" bash scripts/lib/prepare-signal-ffi-xcframework.sh; \
	fi

build: bootstrap preflight
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
		ARCHS=arm64 \
		ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		build
	@echo "==> Embedding daemon helper…"
	mkdir -p "$(APP_BUNDLE)/Contents/Helpers"
	cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_BIN)" "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"
	if [ -f "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_CORE_DYLIB)" ]; then \
		cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_CORE_DYLIB)" "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_CORE_DYLIB)"; \
	else \
		echo "    No $(DAEMON_CORE_DYLIB) produced; daemon is statically linked."; \
	fi
	chmod +x "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"
	@echo "==> Embedding OpenBurnBarCore framework…"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	OPENBURNBAR_CORE_FRAMEWORK="$(DERIVED_DATA)/Build/Products/$(CONFIG)/PackageFrameworks/OpenBurnBarCore.framework"; \
	if [ -d "$$OPENBURNBAR_CORE_FRAMEWORK" ]; then \
		rm -rf "$(APP_BUNDLE)/Contents/Frameworks/OpenBurnBarCore.framework"; \
		cp -R "$$OPENBURNBAR_CORE_FRAMEWORK" "$(APP_BUNDLE)/Contents/Frameworks/"; \
	else \
		echo "    No OpenBurnBarCore.framework produced; app is statically linked."; \
	fi
	@echo "==> Built: $(APP_BUNDLE)"

build-signed: bootstrap preflight
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
	@echo "==> Building signed $(SCHEME) ($(CONFIG))…"
	@TEAM="$(OPENBURNBAR_DEVELOPMENT_TEAM)"; \
	if [ -z "$$TEAM" ]; then \
		IDENTITY="$$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"; \
		if [ -n "$$IDENTITY" ]; then \
			TEAM="$$(security find-certificate -c "$$IDENTITY" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1 || true)"; \
		fi; \
	fi; \
	if [ -n "$$TEAM" ]; then \
		echo "    Using development team $$TEAM (set OPENBURNBAR_DEVELOPMENT_TEAM to override)."; \
		xcodebuild \
			-project $(PROJECT) \
			-scheme $(SCHEME) \
			-configuration $(CONFIG) \
			-destination "$(DESTINATION)" \
			-clonedSourcePackagesDirPath $(CACHE_DIR) \
			-derivedDataPath $(DERIVED_DATA) \
			ARCHS=arm64 \
			ONLY_ACTIVE_ARCH=YES \
			DEVELOPMENT_TEAM=$$TEAM \
			CODE_SIGN_STYLE=Automatic \
			-allowProvisioningUpdates \
			build; \
	else \
		echo "    No OPENBURNBAR_DEVELOPMENT_TEAM set and no Apple Development identity found —"; \
		echo "    building unsigned; the bundle will be ad-hoc signed for local use."; \
		xcodebuild \
			-project $(PROJECT) \
			-scheme $(SCHEME) \
			-configuration $(CONFIG) \
			-destination "$(DESTINATION)" \
			-clonedSourcePackagesDirPath $(CACHE_DIR) \
			-derivedDataPath $(DERIVED_DATA) \
			ARCHS=arm64 \
			ONLY_ACTIVE_ARCH=YES \
			CODE_SIGN_IDENTITY="-" \
			CODE_SIGNING_REQUIRED=NO \
			CODE_SIGNING_ALLOWED=NO \
			build; \
	fi
	@echo "==> Embedding daemon helper…"
	mkdir -p "$(APP_BUNDLE)/Contents/Helpers"
	cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_BIN)" "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"
	if [ -f "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_CORE_DYLIB)" ]; then \
		cp "$(DAEMON_PACKAGE)/.build/release/$(DAEMON_CORE_DYLIB)" "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_CORE_DYLIB)"; \
	else \
		echo "    No $(DAEMON_CORE_DYLIB) produced; daemon is statically linked."; \
	fi
	chmod +x "$(APP_BUNDLE)/Contents/Helpers/$(DAEMON_BIN)"
	@echo "==> Embedding OpenBurnBarCore framework…"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	OPENBURNBAR_CORE_FRAMEWORK="$(DERIVED_DATA)/Build/Products/$(CONFIG)/PackageFrameworks/OpenBurnBarCore.framework"; \
	if [ -d "$$OPENBURNBAR_CORE_FRAMEWORK" ]; then \
		rm -rf "$(APP_BUNDLE)/Contents/Frameworks/OpenBurnBarCore.framework"; \
		cp -R "$$OPENBURNBAR_CORE_FRAMEWORK" "$(APP_BUNDLE)/Contents/Frameworks/"; \
	else \
		echo "    No OpenBurnBarCore.framework produced; app is statically linked."; \
	fi
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development:'; then \
		echo "==> Signing $(APP_BUNDLE) for local install…"; \
		OPENBURNBAR_PRESERVE_SIGNED_ENTITLEMENTS=1 scripts/sign-openburnbar-local.sh "$(APP_BUNDLE)" "AgentLens/Resources/OpenBurnBar.entitlements"; \
	else \
		echo "==> Ad-hoc signing $(APP_BUNDLE) (no Apple Development identity in the keychain)…"; \
		/usr/bin/codesign --force --deep --sign - --timestamp=none "$(APP_BUNDLE)"; \
		/usr/bin/codesign --verify --strict --verbose=2 "$(APP_BUNDLE)"; \
		echo "    NOTE: ad-hoc builds run locally but skip provisioned entitlements"; \
		echo "    (e.g. keychain-backed cloud sign-in). For a developer-signed build,"; \
		echo "    install an Apple Development certificate or set OPENBURNBAR_DEVELOPMENT_TEAM."; \
	fi
	@echo "==> Built signed: $(APP_BUNDLE)"

release-mas: preflight ## Build/export the sandboxed Mac App Store package
	@scripts/build-macos-app-store-release.sh

release-website: preflight ## Build/sign/notarize direct-download DMG/ZIP artifacts
	@scripts/build-macos-website-release.sh

install: build-signed
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

test: ## Run all test suites (Swift packages + macOS + mobile + Android when configured)
	@echo "==> Running Swift package tests…"
	@./scripts/test-openburnbar-swift.sh
	@echo "==> Running macOS app tests…"
	@./scripts/test-openburnbar-app.sh
	@echo "==> Running iOS mobile tests (Simulator when CI=true; physical iPhone otherwise)…"
	@CI=true ./scripts/test-openburnbar-mobile.sh
	@if [ -x android/gradlew ] && [ -n "$${JAVA_HOME:-}" -o -d "$$HOME/.homebrew/opt/openjdk@21" -o -d /opt/homebrew/opt/openjdk@21 ]; then \
		echo "==> Running Android unit tests…"; \
		./scripts/test-openburnbar-android.sh || echo "WARNING: Android tests failed or SDK missing."; \
	fi

test-full: lint ## Full CI parity (core + Functions + extension evals + supply chain)
	@echo "==> Running Functions tests…"
	@npm --prefix functions ci && npm --prefix functions test
	@echo "==> Running extension evals…"
	@./scripts/test-openburnbar-retrieval-evals.sh
	@./scripts/test-openburnbar-replay-evals.sh
	@./scripts/test-openburnbar-extension-host.sh
	@./scripts/test-openburnbar-ts.sh
	@npm --prefix functions run test:firestore-rules
	@./scripts/supply-chain-audit.sh
	@$(MAKE) test

lint: ## Run SwiftLint
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --quiet; \
	else \
		echo "WARNING: swiftlint not found; skipping lint."; \
	fi

debt-check: ## Enforce debt budgets + refresh tech-debt metrics
	@./scripts/debt/check-unsafe-cast-budget.sh
	@./scripts/debt/check-empty-catch-budget.sh
	@./scripts/debt/check-try-optional-budget.sh
	@./scripts/ci/update-tech-debt-metrics.sh

ops-check: ## Callable logging, resilience wiring, ops manifest sanity
	@bash scripts/ci/verify-ops-readiness.sh

ci: debt-check ops-check lint test-full ## Full CI check (matches GitHub PR harness intent)

release-checksums: ## Compute SHA256/SHA512 checksums for release artifacts
	@APP_PATH="$(DERIVED_DATA)/Build/Products/$(CONFIG)/$(APP_NAME)"; \
	if [ ! -d "$$APP_PATH" ]; then \
		echo "ERROR: Build not found at $$APP_PATH. Run 'make build' first."; \
		exit 1; \
	fi; \
	echo "==> Computing checksums for built artifacts…"; \
	echo ""; \
	if [ -f "$$APP_PATH/../OpenBurnBar-$$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*: *//;s/ *//;s/"//g')-macOS.dmg" ]; then \
		DMG_FILE="$$APP_PATH/../OpenBurnBar-$$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*: *//;s/ *//;s/"//g')-macOS.dmg"; \
	else \
		echo "No DMG found. Checksums will cover the .app bundle only."; \
		DMG_FILE=""; \
	fi; \
	if [ -n "$$DMG_FILE" ] && [ -f "$$DMG_FILE" ]; then \
		echo "DMG:"; \
		shasum -a 256 "$$DMG_FILE"; \
		shasum -a 512 "$$DMG_FILE"; \
	fi; \
	VERSION=$$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*: *//;s/ *//;s/"//g'); \
	python3 scripts/generate-sbom.py --version "$$VERSION" --repo-root . --output "checksums-v$$VERSION.txt" 2>/dev/null || true; \
	echo ""; \
	echo "Checksums computed. For signed release checksums, see the GitHub Release assets."

sbom: ## Generate SPDX Software Bill of Materials
	@VERSION=$$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*: *//;s/ *//;s/"//g'); \
	echo "==> Generating SBOM for v$$VERSION…"; \
	python3 scripts/generate-sbom.py --version "$$VERSION" --repo-root .
