import AppKit
import Foundation

// Homebrew cask installs are updated through `brew`, not by replacing the app
// bundle (that would desync the Caskroom). So this channel never downloads or
// installs — it just points the user at the upgrade command.
#if !DISTRIBUTION_MAS

struct HomebrewUpdateChannel {
    /// The cask tap users install from (see homebrew/burnbar.rb).
    static let upgradeCommand = "brew upgrade --cask Ajnunezg/tap/openburnbar"

    func runUpgradeInTerminal() {
        TerminalCommandRunner.open(command: Self.upgradeCommand)
    }
}

/// Opens Terminal.app and runs a command, so the user can watch long-running
/// update work (brew upgrade, source rebuilds) and cancel it.
enum TerminalCommandRunner {
    static func open(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run() // try?-ok(best-effort UX convenience; copy command is the fallback)
    }
}
#endif
