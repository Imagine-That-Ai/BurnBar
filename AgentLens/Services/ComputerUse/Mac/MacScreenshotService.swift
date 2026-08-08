#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore

/// Captures local Mac screenshots for Computer Use approval and audit
/// evidence. The audit chain stores content hashes; the PNG files live
/// beside the session log so a human can later compare the artifact with
/// the recorded hash.
///
/// VisualCaptureMode branching (Subagent C — P0 #1 + #2 fix):
/// - `.cliPTY` never touches Screen Recording / ScreenCaptureKit / CGDisplay*;
///   it renders a PTY placeholder PNG (ANSI-sanitized) so viewers that expect
///   an image still get one, but no desktop pixels leave the Mac.
/// - `.desktop` is fail-closed: it first calls `CGPreflightScreenCaptureAccess()`
///   synchronously (not the 5s/30s poll via `SystemPermissionMonitor`), then
///   validates the target window against `allowedProviderBundles` + `deniedBundleIDs`
///   (including `MacComputerUseDenyRegions.sensitiveBundles` + `ComputerUseDenyRegistry`
///   built-ins like loginwindow/SecurityAgent). If the window is not on-screen,
///   denied, or not in the allowlist, it throws `deniedWindow` so the caller can
///   fall back to PTY + toast + audit entry `screen_recording_denied_fallback_to_pty`.
/// - Both branches write PNG under `computer-use-audit/<session>/screenshots/` with
///   `0o700` directory / `0o600` file (P1 #3 — previously 0755/0644 via umask).
public final class MacScreenshotService: Sendable {
    public struct Capture: Sendable, Equatable {
        public let pngURL: URL
        public let pngData: Data
        public let sha256Hex: String
        public let width: Int
        public let height: Int
    }

    public enum CaptureError: Error, Sendable, Equatable {
        case noMainDisplayImage
        case pngEncodingFailed
        case screenRecordingPermissionDenied
        case deniedWindow
        case windowNotFound
    }

    /// Visual capture surface selector.
    ///
    /// Callers resolve the effective surface via
    /// `SettingsManager.shared.visualCaptureSourceToggleEnabled` + `visualCaptureSource(for:)`
    /// (see `VisualCapturePreferences.swift` B handoff). When the flag is off, callers must
    /// pass `.cliPTY` to preserve idle budgets. When flag is on and provider is Both, they
    /// pass `.desktop(displayID:windowID:)`; eligibility (CLI-only/plugin-only → .cliPTY) is
    /// already enforced by `visualCaptureSource(for:)` so this service trusts the mode it
    /// receives and only enforces the synchronous TCC + window allow/deny gates.
    public enum VisualCaptureMode: Sendable, Equatable {
        case cliPTY
        case desktop(displayID: CGDirectDisplayID, windowID: CGWindowID?)
    }

    // MARK: - Allow / Deny lists

    /// Allowlist — audit-corrected Both set (11 active, Cursor splits into two `AgentProvider`
    /// cases but one bundle). From `catalog.json` `visualSurfaces: ["cli","desktop"]` + plan §1.
    /// Kept in-code so capture stays fail-closed even if catalog probe fails.
    static let allowedProviderBundles: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.todesktop.230313mzl4w4u92",
        "com.warp.Warp",
        "com.factory.app",
        "com.factory.desktop",
        "com.minimax.app",
        "com.minimax.desktop",
        "ai.zcode.app",
        "com.zai.desktop",
        "com.devin.app",
        "com.devin.desktop",
        "com.hermes.app",
        "com.openai.codex-desktop",
        "com.openai.codex.desktop",
        "com.openai.ollama",
        "com.openblock.opencode",
        // Back-compat variants
        "com.anthropic.claude-code",
        "com.todesktop.230313mzl4w4u92.Cursor"
    ]

    /// Deny-list — union of `ComputerUseDenyRegistry.builtInRules` bundleIds +
    /// `MacComputerUseDenyRegions.sensitiveBundles`. Hard-coded for Sendable static;
    /// also extended at runtime via `deniedBundleIDsLive`.
    static let deniedBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.SecurityAgentHelper",
        "com.apple.keychainaccess",
        "com.apple.FileVaultRecoveryUtility",
        "com.apple.systempreferences",
        "com.apple.Terminal"
    ]

    /// Runtime-expanded deny set (includes live registry). Computed lazily so tests can inject.
    private static var deniedBundleIDsLive: Set<String> {
        var s = deniedBundleIDs
        for rule in ComputerUseDenyRegistry.builtInRules {
            if let bid = rule.bundleId { s.insert(bid) }
        }
        // Mirror MacComputerUseDenyRegions defaults
        s.formUnion(MacComputerUseDenyRegions().sensitiveBundles)
        return s
    }

    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    // MARK: - Public entry

    /// Unified capture that branches on visual surface.
    ///
    /// - `.cliPTY`: no `CGPreflightScreenCaptureAccess()` needed, no `SCShareableContent`,
    ///   no `SCStream`. Renders a small PTY placeholder PNG (sanitized label) with the same
    ///   `0o700`/`0o600` + `SHA256` chain properties as the desktop path so audit parity holds.
    /// - `.desktop`: synchronous `CGPreflight` gate first; then window allow/deny; then
    ///   `CGDisplayCreateImage` or `CGWindowListCreateImage(..., .optionOnScreenOnly, windowID, .bestResolution)`.
    public func capture(
        mode: VisualCaptureMode,
        label: String,
        sessionId: ComputerUseSessionID,
        entryIndexHint: Int
    ) throws -> Capture {
        switch mode {
        case .cliPTY:
            return try captureCLI(label: label, sessionId: sessionId, entryIndexHint: entryIndexHint)
        case .desktop(let displayID, let windowID):
            return try captureDesktop(
                displayID: displayID,
                windowID: windowID,
                label: label,
                sessionId: sessionId,
                entryIndexHint: entryIndexHint
            )
        }
    }

    /// Legacy wrapper — preserves callers that have not yet migrated to `capture(mode:)`.
    /// Now routes through `.desktop(CGMainDisplayID(), nil)` with the same P0 gates.
    public func captureMainDisplay(
        label: String,
        sessionId: ComputerUseSessionID,
        entryIndexHint: Int
    ) throws -> Capture {
        try capture(
            mode: .desktop(displayID: CGMainDisplayID(), windowID: nil),
            label: label,
            sessionId: sessionId,
            entryIndexHint: entryIndexHint
        )
    }

    // MARK: - Desktop

    private func captureDesktop(
        displayID: CGDirectDisplayID,
        windowID: CGWindowID?,
        label: String,
        sessionId: ComputerUseSessionID,
        entryIndexHint: Int
    ) throws -> Capture {
        // P0 #1 — synchronous TCC gate before ANY CG* call (closes 5-30s poll window)
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.screenRecordingPermissionDenied
        }

        let image: CGImage
        if let windowID {
            try validateWindow(windowID: windowID)
            // CGWindowListCreateImage with onScreenOnly ensures we only capture composited on-screen pixels.
            guard let windowImage = CGWindowListCreateImage(
                CGRect.null,
                .optionOnScreenOnly,
                windowID,
                .bestResolution
            ) else {
                throw CaptureError.windowNotFound
            }
            image = windowImage
        } else {
            // Display path — still requires permission (already gated). No bundle filter for bare display;
            // caller should prefer windowID when provider window is known to satisfy P0 #2 least-privilege.
            // Display capture via ScreenCaptureKit (`SCContentFilter(display:excludingApplications:)`) excludes
            // own bundle; here we capture the whole display but the audit still records the hash.
            guard let displayImage = CGDisplayCreateImage(displayID) else {
                throw CaptureError.noMainDisplayImage
            }
            image = displayImage
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }
        return try writeCapture(
            png: png,
            image: image,
            label: label,
            sessionId: sessionId,
            entryIndexHint: entryIndexHint
        )
    }

    /// Window filtering for `.desktop` (P0 #2).
    /// Uses `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` + `NSRunningApplication`
    /// PID→bundle lookup, then checks `allowedProviderBundles` and `deniedBundleIDsLive`.
    /// Fail-closed to PTY if denied or not allowed.
    private func validateWindow(windowID: CGWindowID) throws {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw CaptureError.deniedWindow
        }
        guard let dict = windowList.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                || ($0[kCGWindowNumber as String] as? CGWindowID) == windowID
        }) else {
            throw CaptureError.windowNotFound
        }
        // kCGWindowOwnerPID → NSRunningApplication bundleIdentifier
        let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            ?? (dict[kCGWindowOwnerPID as String] as? pid_t)
            ?? 0
        guard pid != 0, let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier, !bundleID.isEmpty
        else {
            // Cannot resolve bundle — fail closed (do not capture unknown window)
            throw CaptureError.deniedWindow
        }
        let denied = Self.deniedBundleIDsLive
        if denied.contains(bundleID) {
            throw CaptureError.deniedWindow
        }
        if !Self.allowedProviderBundles.contains(bundleID) {
            throw CaptureError.deniedWindow
        }
        // Extra deny for System Settings Privacy pane (windowTitleRegex in registry)
        if bundleID == "com.apple.systempreferences" {
            // Registry denies only Privacy & Security pane; we deny the bundle outright for capture to be conservative.
            throw CaptureError.deniedWindow
        }
    }

    // MARK: - CLI PTY (no ScreenCaptureKit / CGDisplay)

    private func captureCLI(
        label: String,
        sessionId: ComputerUseSessionID,
        entryIndexHint: Int
    ) throws -> Capture {
        // Must NOT call CGPreflight, SCShareableContent, CGDisplayCreateImage, or SCStream.
        // Render a placeholder PNG from sanitized PTY text so audit chain still gets a hash.
        let sanitizedLabel = sanitizedANSI(label)
        let size = NSSize(width: 1280, height: 720)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let header = "PTY Capture — \(sanitizedLabel)"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let body = "\(header)\n\(timestamp)\n\nTerminal output captured via PTY (no Screen Recording permission required).\nThis placeholder PNG preserves the audit hash chain without desktop pixels."
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: paragraph
        ]
        let inset: CGFloat = 24
        let textRect = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        (body as NSString).draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw CaptureError.pngEncodingFailed
        }
        return try writeCapture(
            png: png,
            image: cgImage,
            label: label,
            sessionId: sessionId,
            entryIndexHint: entryIndexHint
        )
    }

    /// Strip ANSI escape sequences (CSI ... m and OSC ... BEL) before rendering to PNG.
    /// Keeps the text audit-compatible without leaking terminal control chars into the image.
    private func sanitizedANSI(_ raw: String) -> String {
        // Fast path: no ESC
        guard raw.contains("\u{1B}") else { return raw }
        var out = raw
        // Strip CSI sequences: ESC [ ... m / K / J etc
        // Covers: \x1B[0m, \x1B[38;5;...m, \x1B[2K, etc.
        let csiPattern = "\u{1B}\\[[0-9;:?]*[ -/]*[@-~]"
        if let regex = try? NSRegularExpression(pattern: csiPattern, options: []) { // try?-ok(static CSI pattern always compiles)
            out = regex.stringByReplacingMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Strip OSC sequences: ESC ] ... BEL or ESC \
        let oscPattern = "\u{1B}\\][^\u{07}]*(\u{07}|\u{1B}\\\\)"
        if let regex = try? NSRegularExpression(pattern: oscPattern, options: []) { // try?-ok(static OSC pattern always compiles)
            out = regex.stringByReplacingMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Strip remaining single ESC + char
        out = out.replacingOccurrences(of: "\u{1B}", with: "")
        return out
    }

    // MARK: - Write (FS perms P1 #3)

    private func writeCapture(
        png: Data,
        image: CGImage,
        label: String,
        sessionId: ComputerUseSessionID,
        entryIndexHint: Int
    ) throws -> Capture {
        let directory = baseDirectory
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
        // P1 #3 — 0o700 dirs, 0o600 files (was default 0755/0644 via umask)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) // try?-ok(best-effort harden existing dir)
            // Also harden parent session dir
            let parent = directory.deletingLastPathComponent()
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) // try?-ok(best-effort harden session parent)
        }

        let filename = "\(String(format: "%06d", entryIndexHint))-\(sanitized(label)).png"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try png.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // try?-ok(best-effort harden capture file)

        return Capture(
            pngURL: url,
            pngData: png,
            sha256Hex: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            width: image.width,
            height: image.height
        )
    }

    private func sanitized(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = label.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let joined = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return joined.isEmpty ? "capture" : joined
    }
}
#endif
