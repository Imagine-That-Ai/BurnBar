import Foundation

/// Phase 14 — Pattern classifier that maps a noisy macOS tool failure
/// string into a `SystemPermissionKind`. Used by the Mac daemon to
/// hoist Hermes tool failures into structured permission frames, and
/// reused on iOS as a fallback so the chat surface can still render a
/// pill even when the Mac-side hook is unavailable (e.g. Hermes lives
/// on another host).
///
/// The classifier is deliberately conservative — every match is
/// keyword-anchored and gated by a TCC-shaped phrase, so model prose
/// like "I cannot take a screenshot" without an OS-level error does
/// not falsely trigger the permission card.
public struct SystemPermissionToolFailureClassifier: Sendable {
    public struct Match: Hashable, Sendable {
        public let kind: SystemPermissionKind
        /// Optional target bundle id for Automation kinds (parsed from
        /// the failure message when possible).
        public let bundleId: String?
        /// Short category string the Mac audit chain ingests
        /// (`"tccd"`, `"AppleEvents"`, etc.).
        public let category: String

        public init(kind: SystemPermissionKind, bundleId: String? = nil, category: String) {
            self.kind = kind
            self.bundleId = bundleId
            self.category = category
        }
    }

    public init() {}

    /// Classify a tool failure body. Returns `nil` when no TCC denial is
    /// detected. Case-insensitive across all rules.
    public func classify(toolResult body: String) -> Match? {
        classify(body)
    }

    /// Classify an assistant-emitted apology / error sentence as a
    /// heuristic fallback. Same rules as `classify(toolResult:)` but
    /// limited to phrases that almost always indicate a missing
    /// permission rather than a refusal.
    public func classify(assistantText text: String) -> Match? {
        let lowered = text.lowercased()
        guard containsPermissionTrigger(lowered) else { return nil }
        return classify(text)
    }

    /// Core dispatcher — case-insensitive checks shared between tool
    /// and assistant entry points.
    private func classify(_ raw: String) -> Match? {
        let body = raw.lowercased()

        // Screen Recording — most common path; covers screencapture(1),
        // SCStream errors, and CGDisplay capture failures.
        if matchesScreenRecording(body) {
            return Match(kind: .screenRecording, bundleId: nil, category: "tccd_screen_recording")
        }

        // Accessibility — AXIsProcessTrusted, AXError, accessibility APIs.
        if matchesAccessibility(body) {
            return Match(kind: .accessibility, bundleId: nil, category: "ax_trust")
        }

        // Automation — needs to come before microphone/camera because the
        // bundle-id capture is more specific than the AV substrings.
        if let bundleId = automationBundleId(body) {
            return Match(kind: .automation, bundleId: bundleId, category: "apple_events")
        }
        if body.contains("not allowed to send apple events")
            || body.contains("not allowed to use apple events")
            || body.contains("not authorized to send apple events")
            || body.contains("-1743")
            || (body.contains("apple events") && body.contains("not permitted")) {
            return Match(kind: .automation, bundleId: nil, category: "apple_events")
        }

        // Microphone before Camera (mic descriptors are more specific).
        if matchesMicrophone(body) {
            return Match(kind: .microphone, bundleId: nil, category: "av_audio")
        }
        if matchesCamera(body) {
            return Match(kind: .camera, bundleId: nil, category: "av_video")
        }

        // Full Disk Access — sandbox + ~/Library hits.
        if matchesFullDiskAccess(body) {
            return Match(kind: .fullDiskAccess, bundleId: nil, category: "sandbox_fda")
        }

        return nil
    }

    // MARK: - Rule helpers

    private func matchesScreenRecording(_ body: String) -> Bool {
        let screenAnchors = [
            "screen recording",
            "screen capture",
            "screencapturekit",
            "scstream",
            "cgdisplay",
            "cgwindowlist",
            "screencapture:"
        ]
        let denialAnchors = [
            "permission",
            "not allowed",
            "denied",
            "not authorized",
            "not granted",
            "is required",
            "requires"
        ]
        let containsScreen = screenAnchors.contains { body.contains($0) }
        let containsDenial = denialAnchors.contains { body.contains($0) }
        if containsScreen && containsDenial { return true }
        // Catch-all: explicit screencapture error string.
        if body.contains("screencapture") && body.contains("cannot") { return true }
        return false
    }

    private func matchesAccessibility(_ body: String) -> Bool {
        let anchors = [
            "axisprocesstrusted",
            "ax error",
            "accessibility access",
            "accessibility permission",
            "accessibility is required",
            "not trusted to use accessibility",
            "kaxerrorpermission",
            "accessibility api",
            "accessibility-related"
        ]
        return anchors.contains { body.contains($0) }
    }

    private func matchesMicrophone(_ body: String) -> Bool {
        let anchors = [
            "microphone permission",
            "microphone access",
            "microphone is denied",
            "microphone access has been denied",
            "no permission to access the microphone",
            "avcapturedevice.audio",
            "avauthorizationstatus.denied (audio)",
            "audio capture is not allowed",
            "audio input"
        ]
        return anchors.contains { body.contains($0) }
    }

    private func matchesCamera(_ body: String) -> Bool {
        let anchors = [
            "camera permission",
            "camera access",
            "camera is denied",
            "camera access has been denied",
            "no permission to access the camera",
            "avcapturedevice.video",
            "avauthorizationstatus.denied (video)",
            "video capture is not allowed",
            "video input"
        ]
        return anchors.contains { body.contains($0) }
    }

    private func matchesFullDiskAccess(_ body: String) -> Bool {
        // Pure "Operation not permitted" is too noisy on its own — gate
        // on the protected-path tells so model prose like "the operation
        // was not permitted by my rules" cannot trigger this path.
        let pathHints = [
            "~/library/",
            "/library/safari",
            "/library/mail",
            "/library/messages",
            "/library/cookies",
            "containers/",
            "tcc.db"
        ]
        let phraseHints = [
            "full disk access",
            "fda",
            "full-disk access",
            "operation not permitted",
            "permission denied"
        ]
        let containsPath = pathHints.contains { body.contains($0) }
        let containsPhrase = phraseHints.contains { body.contains($0) }
        return containsPath && containsPhrase
    }

    /// Parse a bundle id out of an Automation-shaped error string. We
    /// look for a bundle-shaped pattern after "controlling" or "app" or
    /// inside `(bundle: ...)` payloads. Returns nil when the bundle id
    /// cannot be parsed but the message still looks Automation-shaped —
    /// the dispatcher rule above keeps the kind for that case.
    private func automationBundleId(_ body: String) -> String? {
        guard body.contains("apple events")
                || body.contains("automation")
                || body.contains("scripting bridge")
                || body.contains("nsapplescript") else {
            return nil
        }
        if let match = body.range(of: #"(com\.[a-z0-9_\-\.]+|app\.[a-z0-9_\-\.]+|org\.[a-z0-9_\-\.]+)"#,
                                  options: .regularExpression) {
            let bundle = String(body[match])
            // Trim trailing punctuation the regex may have grabbed.
            return bundle.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)\""))
        }
        return nil
    }

    /// Words that gate the assistant-text classifier. Without one of
    /// these we never escalate model prose to a structured permission
    /// card — model refusals like "Sorry, I can't do that" stay text.
    private func containsPermissionTrigger(_ body: String) -> Bool {
        let triggers = [
            "permission",
            "not allowed",
            "denied",
            "not authorized",
            "is required",
            "requires",
            "macos requires",
            "system settings",
            "privacy & security",
            "privacy and security"
        ]
        return triggers.contains { body.contains($0) }
    }
}
