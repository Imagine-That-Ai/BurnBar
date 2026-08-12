# OpenBurnBar Homebrew cask release template.
#
# This checked-in template is intentionally not installable or publishable.
# scripts/update-homebrew.sh replaces every PENDING_RELEASE_* value only after
# verifying the published DMG and its v<version> tag against the exact source
# commit in Imagine-That-Ai/BurnBar. Tap publication is a separate, explicit,
# verified command; updating this file alone never publishes Homebrew.
#
# Source repository: Imagine-That-Ai/BurnBar
# Source commit: PENDING_RELEASE_COMMIT
# Release tag: PENDING_RELEASE_TAG
#
# Prepare the exact cask:
#   scripts/update-homebrew.sh update \
#     --version <version> \
#     --candidate-sha <40-hex release commit>
#
# Publish from a clean Imagine-That-Ai/homebrew-tap checkout:
#   scripts/update-homebrew.sh publish \
#     --version <version> \
#     --candidate-sha <40-hex release commit> \
#     --tap-dir <tap checkout> \
#     --receipt <publication receipt path>

cask "openburnbar" do
  version "PENDING_RELEASE_VERSION"
  sha256 "PENDING_RELEASE_SHA256"

  url "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v#{version}/OpenBurnBar-#{version}-macOS.dmg"
  name "OpenBurnBar"
  desc "Menu bar app for tracking AI agent token usage across Claude, Codex, and more"
  homepage "https://github.com/Imagine-That-Ai/BurnBar"

  depends_on macos: ">= :sonoma"

  app "OpenBurnBar.app"

  zap trash: [
    "~/Library/Application Support/OpenBurnBar",
    "~/Library/Caches/com.openburnbar.app",
    "~/Library/Preferences/com.openburnbar.app.plist",
  ]
end
