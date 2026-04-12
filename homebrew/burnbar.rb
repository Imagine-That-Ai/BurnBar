# Homebrew Cask formula for OpenBurnBar
#
# To use this formula, the maintainer should:
# 1. Create a GitHub repo: Ajnunezg/homebrew-tap
# 2. Copy this file to: Casks/openburnbar.rb
# 3. Update the version, url, and sha256 for each release
# 4. Users install with: brew install --cask Ajnunezg/tap/openburnbar
#
# The sha256 and url are updated automatically by the release workflow
# once notarized DMGs are being produced.

cask "openburnbar" do
  version "0.1.0-beta"
  sha256 :no_check # Replace with actual SHA256 once notarized builds exist

  url "https://github.com/Ajnunezg/BurnBar/releases/download/v#{version}/OpenBurnBar-#{version}-macOS.dmg"
  name "OpenBurnBar"
  desc "Menu bar app for tracking AI agent token usage across Claude, Codex, and more"
  homepage "https://github.com/Ajnunezg/BurnBar"

  depends_on macos: ">= :sonoma"

  app "OpenBurnBar.app"

  zap trash: [
    "~/Library/Application Support/OpenBurnBar",
    "~/Library/Caches/com.openburnbar.app",
    "~/Library/Preferences/com.openburnbar.app.plist",
  ]
end
