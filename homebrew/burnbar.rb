# Homebrew Cask formula for BurnBar
#
# To use this formula, the maintainer should:
# 1. Create a GitHub repo: Ajnunezg/homebrew-tap
# 2. Copy this file to: Casks/burnbar.rb
# 3. Update the version, url, and sha256 for each release
# 4. Users install with: brew install --cask Ajnunezg/tap/burnbar
#
# The sha256 and url are updated automatically by the release workflow
# once notarized DMGs are being produced.

cask "burnbar" do
  version "0.1.0-beta"
  sha256 :no_check # Replace with actual SHA256 once notarized builds exist

  url "https://github.com/Ajnunezg/BurnBar/releases/download/v#{version}/BurnBar-#{version}-macOS.dmg"
  name "BurnBar"
  desc "Menu bar app for tracking AI agent token usage across Claude, Codex, and more"
  homepage "https://github.com/Ajnunezg/BurnBar"

  depends_on macos: ">= :sonoma"

  app "BurnBar.app"

  zap trash: [
    "~/Library/Application Support/BurnBar",
    "~/Library/Caches/com.burnbar.app",
    "~/Library/Preferences/com.burnbar.app.plist",
  ]
end
