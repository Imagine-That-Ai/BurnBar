import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

extension AgentToolBroker {
    /// Home-relative read roots dev tooling needs (toolchains, language version
    /// managers, package caches). Everything else under home is denied unless it
    /// is the active workspace.
    static let restrictedShellHomeReadAllowlistSubpaths: [String] = [
        "/.rustup", "/.cargo/bin", "/.cargo/registry", "/.rbenv",
        "/.pyenv", "/.nvm", "/.nodenv", "/.asdf", "/.local/share/mise",
        "/.swiftpm", "/.cache", "/Library/Developer", "/.gradle/caches",
        "/.m2/repository", "/.npm", "/.bun/bin", "/.deno", "/go/pkg",
        "/.zshenv", "/.zprofile", "/.zshrc", "/.profile", "/.bashrc", "/.bash_profile"
    ]

    /// Home-relative state and credential directories that stay explicitly denied
    /// even though the broader T-TOOL-10 profile denies home file data by default.
    static let restrictedShellHomeReadDenySubpaths: [String] = [
        "/Library/Application Support/com.openburnbar.AgentLens",
        "/.openburnbar",
        "/.config/openburnbar",
        "/.terraform.d",
        "/.cloudflared",
        "/.config/git",
        "/Library/Application Support/Slack"
    ]

    /// Home-relative credential files that should never be exposed to restricted
    /// shell reads, including when future tooling allowlists expand.
    static let restrictedShellHomeReadDenyLiterals: [String] = [
        "/.env",
        "/.envrc",
        "/.cargo/credentials",
        "/.cargo/credentials.toml",
        "/.gem/credentials",
        "/.config/configstore/firebase-tools.json"
    ]

    /// Absolute system/toolchain read roots needed for restricted-shell startup
    /// and common developer CLIs. The restricted shell must not use a broad
    /// "read any non-home path" rule because that exposes arbitrary files from
    /// `/private`, removable volumes, sibling repos, and host-local state.
    static let restrictedShellSystemReadAllowlistSubpaths: [String] = [
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/usr/share",
        "/System",
        "/Library/Apple",
        "/Library/Developer",
        "/Library/Frameworks",
        "/Applications/Xcode.app",
        "/Applications/Xcode-beta.app",
        "/Applications/Xcode-26.6.0-Release.Candidate.app",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/opt/homebrew/Cellar",
        "/opt/homebrew/Library/Homebrew",
        "/opt/homebrew/lib",
        "/opt/homebrew/opt",
        "/opt/homebrew/share",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/local/Cellar",
        "/usr/local/Homebrew",
        "/usr/local/lib",
        "/usr/local/opt",
        "/usr/local/share"
    ]

    /// zsh reads `/etc/zshenv` before user rc files. Allow only that system
    /// literal rather than opening the whole `/private/etc` tree.
    static let restrictedShellSystemReadAllowlistLiterals: [String] = [
        "/private/etc/zshenv"
    ]

    /// Non-system roots where the restricted shell should not read arbitrary
    /// file data. Each deny is emitted with explicit exceptions for the active
    /// workspace and the allowlisted system/home toolchain roots.
    static let restrictedShellNonHomeReadDenyRegexes: [String] = [
        "^/Applications/",
        "^/Library/",
        "^/Users/",
        "^/Volumes/",
        "^/cores/",
        "^/etc/",
        "^/home/",
        "^/opt/",
        "^/private/",
        "^/tmp/",
        "^/usr/local/",
        "^/var/"
    ]

    /// Clean environment for the restricted shell. `Process` inherits the parent
    /// environment by default, which can expose API tokens even when Seatbelt
    /// blocks home-directory file reads. Keep only deterministic execution basics.
    static func restrictedShellEnvironment(
        workspacePath: String,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        let workspace = canonicalSandboxPath(workspacePath)
        let home = canonicalSandboxPath(homePath)
        let pathEntries = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.homebrew/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin"
        ]
        return [
            "PATH": pathEntries.joined(separator: ":"),
            "HOME": home,
            "PWD": workspace,
            "SHELL": "/bin/zsh",
            "TMPDIR": workspace,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb"
        ]
    }

    /// Seatbelt profile for the **restricted** agent shell (`shell_run`).
    ///
    /// Hardening layers (T-TOOL-10 + prior F3/F9):
    ///   * default-deny operations, then explicitly allow only process/IPC/sysctl
    ///     operations needed to launch local developer tools.
    ///   * no network operation family is allowed, so ordinary exfiltration paths
    ///     fail before connecting.
    ///   * writes stay confined to the workspace.
    ///   * file data keeps the broad macOS launch grant required by dyld and
    ///     system tooling, then regex deny rules carve user/writable/non-system
    ///     roots back down to the active workspace plus explicit system/home
    ///     toolchain roots.
    static func restrictedShellSandboxProfile(
        workspacePath: String,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let canonicalWorkspacePath = canonicalSandboxPath(workspacePath)
        let canonicalHomePath = canonicalSandboxPath(homePath)
        let ws = escapeSandboxProfileString(canonicalWorkspacePath)
        let home = escapeSandboxProfileString(canonicalHomePath)

        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(deny network*)",
            "(allow process*)",
            "(allow mach*)",
            "(allow sysctl*)",
            "(allow ipc*)",
            "(allow file-read-metadata)",
            "(allow file-map-executable)",
            "(allow file-read-data (require-not (subpath \"\(home)\")))",
            "(allow file-read* (subpath \"\(ws)\"))",
            "(allow file-write* (subpath \"\(ws)\"))"
        ]
        var nonHomeReadDenyAllowedSubpaths = [canonicalWorkspacePath]
        for subpath in restrictedShellSystemReadAllowlistSubpaths {
            let canonicalSubpath = canonicalSandboxPath(subpath)
            nonHomeReadDenyAllowedSubpaths.append(canonicalSubpath)
            lines.append("(allow file-read* (subpath \"\(escapeSandboxProfileString(canonicalSubpath))\"))")
        }
        for subpath in restrictedShellHomeReadAllowlistSubpaths {
            nonHomeReadDenyAllowedSubpaths.append(canonicalHomePath + subpath)
        }
        var nonHomeReadDenyAllowedLiterals: [String] = []
        for literal in restrictedShellSystemReadAllowlistLiterals {
            let canonicalLiteral = canonicalSandboxPath(literal)
            nonHomeReadDenyAllowedLiterals.append(canonicalLiteral)
            lines.append("(allow file-read* (literal \"\(escapeSandboxProfileString(canonicalLiteral))\"))")
        }
        for regex in restrictedShellNonHomeReadDenyRegexes {
            lines.append(restrictedShellReadDenyRule(
                regex: regex,
                allowedSubpaths: nonHomeReadDenyAllowedSubpaths,
                allowedLiterals: nonHomeReadDenyAllowedLiterals
            ))
        }
        for subpath in restrictedShellHomeReadDenySubpaths {
            let homeSubpath = canonicalHomePath + subpath
            lines.append("(deny file-read* (subpath \"\(escapeSandboxProfileString(homeSubpath))\"))")
        }
        for literal in restrictedShellHomeReadDenyLiterals {
            let homeLiteral = canonicalHomePath + literal
            lines.append("(deny file-read* (literal \"\(escapeSandboxProfileString(homeLiteral))\"))")
        }
        // Re-allow only the null/stdio device nodes so ordinary redirects keep
        // working (`… 2>/dev/null`). Writes otherwise stay strictly confined to
        // the workspace — the anti-persistence guarantee that blocks ~/.ssh,
        // LaunchAgents, and shell rc files. Temp dirs are intentionally NOT
        // re-allowed (that would broaden writes and defeat confinement); tools
        // can use the workspace as scratch.
        for device in ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"] {
            lines.append("(allow file-write* (literal \"\(device)\"))")
        }
        lines.append("(allow file-write* (subpath \"/dev/fd\"))")

        for subpath in restrictedShellHomeReadAllowlistSubpaths {
            let homeSubpath = canonicalHomePath + subpath
            lines.append("(allow file-read* (subpath \"\(escapeSandboxProfileString(homeSubpath))\"))")
        }
        return lines.joined(separator: "\n")
    }

    private static func restrictedShellReadDenyRule(
        regex: String,
        allowedSubpaths: [String],
        allowedLiterals: [String]
    ) -> String {
        var clauses = ["(regex \"\(escapeSandboxProfileString(regex))\")"]
        clauses += allowedSubpaths.map {
            "(require-not (subpath \"\(escapeSandboxProfileString($0))\"))"
        }
        clauses += allowedLiterals.map {
            "(require-not (literal \"\(escapeSandboxProfileString($0))\"))"
        }
        return "(deny file-read-data (require-all \(clauses.joined(separator: " "))))"
    }

    private static func canonicalSandboxPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(standardized, &buffer) != nil {
            return String(cString: buffer)
        }
        #endif
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    private static func escapeSandboxProfileString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
