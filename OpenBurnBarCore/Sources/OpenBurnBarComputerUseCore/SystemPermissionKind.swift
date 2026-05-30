import Foundation
import OpenBurnBarCore

/// Phase 14 — System Permission Concierge.
///
/// Domain-level mirror of `HermesRealtimeRelaySystemPermissionKind` with
/// display strings, SF Symbol names, and System Settings deep links so
/// every surface (Mac monitor, iOS sheet, Android bottom sheet, tests)
/// reads the same metadata from one source. Wire types stay in
/// `OpenBurnBarCore` to keep the relay envelope free of UI concerns;
/// this layer adds the per-kind copy used to render the chat affordance.
public enum SystemPermissionKind: String, CaseIterable, Hashable, Sendable, Codable {
    case screenRecording
    case accessibility
    case remoteDesktop
    case systemExtension
    case camera
    case microphone
    case fullDiskAccess
    case automation

    public init(wire: HermesRealtimeRelaySystemPermissionKind) {
        switch wire {
        case .screenRecording: self = .screenRecording
        case .accessibility:   self = .accessibility
        case .remoteDesktop:   self = .remoteDesktop
        case .systemExtension: self = .systemExtension
        case .camera:          self = .camera
        case .microphone:      self = .microphone
        case .fullDiskAccess:  self = .fullDiskAccess
        case .automation:      self = .automation
        }
    }

    public var wire: HermesRealtimeRelaySystemPermissionKind {
        switch self {
        case .screenRecording: return .screenRecording
        case .accessibility:   return .accessibility
        case .remoteDesktop:   return .remoteDesktop
        case .systemExtension: return .systemExtension
        case .camera:          return .camera
        case .microphone:      return .microphone
        case .fullDiskAccess:  return .fullDiskAccess
        case .automation:      return .automation
        }
    }

    /// Two-word title used in chat cards and sheets ("Screen Recording").
    public var displayTitle: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility:   return "Accessibility"
        case .remoteDesktop:   return "Remote Desktop"
        case .systemExtension: return "Virtual Keyboard"
        case .camera:          return "Camera"
        case .microphone:      return "Microphone"
        case .fullDiskAccess:  return "Full Disk Access"
        case .automation:      return "Automation"
        }
    }

    /// Short subtitle for the pill / sheet hero ("on your Mac").
    public var displaySubtitle: String {
        switch self {
        case .screenRecording: return "on your Mac"
        case .accessibility:   return "for OpenBurnBar"
        case .remoteDesktop:   return "for locked screen access"
        case .systemExtension: return "for physical input"
        case .camera:          return "on your Mac"
        case .microphone:      return "on your Mac"
        case .fullDiskAccess:  return "for OpenBurnBar"
        case .automation:      return "for the requested app"
        }
    }

    /// SF Symbol name (also valid for Android Material symbols via the
    /// `MaterialSymbols.SystemPermissionKind` mapping in the Android
    /// parity port).
    public var sfSymbolName: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility:   return "accessibility"
        case .remoteDesktop:   return "desktopcomputer"
        case .systemExtension: return "keyboard.badge.ellipsis"
        case .camera:          return "video.fill"
        case .microphone:      return "mic.fill"
        case .fullDiskAccess:  return "externaldrive.fill.badge.checkmark"
        case .automation:      return "applescript"
        }
    }

    /// Material Symbol name used by the Android Compose sheet.
    public var materialIconName: String {
        switch self {
        case .screenRecording: return "screen_record"
        case .accessibility:   return "accessibility_new"
        case .remoteDesktop:   return "desktop_windows"
        case .systemExtension: return "keyboard_external_input"
        case .camera:          return "videocam"
        case .microphone:      return "mic"
        case .fullDiskAccess:  return "folder_managed"
        case .automation:      return "smart_toy"
        }
    }

    /// System Settings deep link. Opens the Privacy & Security pane for
    /// the relevant TCC bucket. `nil` for kinds that don't ship a
    /// stable deep link in current macOS versions.
    public var systemSettingsDeepLink: String? {
        switch self {
        case .screenRecording: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:   return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .remoteDesktop:   return "x-apple.systempreferences:com.apple.preference.security?Privacy_RemoteDesktop"
        case .systemExtension: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Extensions"
        case .camera:          return "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .microphone:      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .fullDiskAccess:  return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .automation:      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
    }

    /// Numbered step copy rendered in the sheet's footer. iOS-only —
    /// Android substitutes `bracketReplacement` for the bundle name.
    public func numberedInstructions(bundleName: String? = nil) -> [String] {
        switch self {
        case .screenRecording:
            return [
                "Open System Settings on your Mac",
                "Go to Privacy & Security → Screen Recording",
                "Toggle OpenBurnBar on"
            ]
        case .accessibility:
            return [
                "Open System Settings on your Mac",
                "Go to Privacy & Security → Accessibility",
                "Toggle OpenBurnBar on"
            ]
        case .remoteDesktop:
            return [
                "Open System Settings on your Mac",
                "Go to Privacy & Security → Remote Desktop",
                "Toggle OpenBurnBar on"
            ]
        case .systemExtension:
            return [
                "Click Set Up Input in OpenBurnBar",
                "Approve the macOS administrator prompt",
                "Approve OpenBurnBar in Privacy & Security if macOS asks"
            ]
        case .camera:
            return [
                "On your Mac, accept the camera prompt",
                "Or open Privacy & Security → Camera",
                "Toggle OpenBurnBar on"
            ]
        case .microphone:
            return [
                "On your Mac, accept the microphone prompt",
                "Or open Privacy & Security → Microphone",
                "Toggle OpenBurnBar on"
            ]
        case .fullDiskAccess:
            return [
                "Open System Settings on your Mac",
                "Go to Privacy & Security → Full Disk Access",
                "Add OpenBurnBar and toggle it on"
            ]
        case .automation:
            let target = bundleName ?? "the target app"
            return [
                "On your Mac, accept the Automation prompt for \(target)",
                "Or open Privacy & Security → Automation",
                "Allow OpenBurnBar to control \(target)"
            ]
        }
    }

    /// Default macOS action when the phone taps "Grant on this Mac".
    /// Kinds that ship a programmatic prompt use `promptAndOpenSettings`;
    /// kinds without one fall through to `openSettings`.
    public var defaultAction: HermesRealtimeRelaySystemPermissionAction {
        switch self {
        case .screenRecording, .accessibility, .remoteDesktop:
            return .promptAndOpenSettings
        case .systemExtension:
            return .promptAndOpenSettings
        case .camera, .microphone:
            // AVCaptureDevice.requestAccess surfaces a native dialog
            // without needing System Settings on a fresh state.
            return .prompt
        case .fullDiskAccess:
            return .openSettings
        case .automation:
            return .promptAndOpenSettings
        }
    }

    /// First-run wizard copy. Three plain-language examples of what an
    /// agent **cannot** do for the user when this bucket is denied. The
    /// onboarding card stacks these vertically so the user understands
    /// the cost of skipping each permission before they decide.
    public var onboardingDenialExamples: [String] {
        switch self {
        case .screenRecording:
            return [
                "Read what's on your screen to summarize a long PDF or webpage",
                "Notice a red error in your terminal and offer to fix it",
                "Look over your shoulder to help with the design you're working on"
            ]
        case .accessibility:
            return [
                "Click a button, type a sentence, or scroll a page for you",
                "Drive Cursor, VS Code, or any other app on your behalf",
                "Move or resize a window so two things sit side by side"
            ]
        case .remoteDesktop:
            return [
                "Show your Mac's locked login screen on your trusted phone",
                "Keep a remote session attached to the physical display",
                "Verify the screen actually unlocked before resuming Mercury"
            ]
        case .systemExtension:
            return [
                "Type at the macOS login window as physical keyboard input",
                "Dismiss Touch ID-first lock screens without a special VNC password",
                "Unlock the real console instead of a hidden virtual session"
            ]
        case .camera:
            return [
                "Read what's printed on the paper you're holding up",
                "Point out the cable that's plugged into the wrong port",
                "Watch your space for anything you forgot to grab"
            ]
        case .microphone:
            return [
                "Listen while you think out loud and turn it into notes",
                "Transcribe a meeting and pull out the action items",
                "Run any voice-first interaction with Hermes"
            ]
        case .fullDiskAccess:
            return [
                "Search your Mail, Messages, or Calendar history",
                "Find a file inside Time Machine or another protected folder",
                "Pull a screenshot out of an old backup"
            ]
        case .automation:
            return [
                "Ask Cursor to open a file or run a workflow",
                "Ask Safari or Chrome to load a page and read it back",
                "Ask Finder, Notes, or Reminders to do something for you"
            ]
        }
    }

    /// Short one-liner shown under the card title in the onboarding
    /// wizard. Mirrors `heroExplanation` but framed as a positive
    /// capability so the user knows what enabling unlocks.
    public var onboardingCapabilitySummary: String {
        switch self {
        case .screenRecording: return "Lets the agent see your screen."
        case .accessibility:   return "Lets the agent click, type, and inspect for you."
        case .remoteDesktop:   return "Lets trusted devices see the locked login screen."
        case .systemExtension: return "Lets OpenBurnBar send physical-style input at login."
        case .camera:          return "Lets the agent see through your Mac's camera."
        case .microphone:      return "Lets the agent hear what you say."
        case .fullDiskAccess:  return "Lets the agent reach folders macOS protects."
        case .automation:      return "Lets the agent drive other apps on your Mac."
        }
    }

    /// One-liner used in the iOS sheet hero, just below the headline.
    public var heroExplanation: String {
        switch self {
        case .screenRecording:
            return "Your Mac needs Screen Recording so OpenBurnBar can grab the screen for this agent."
        case .accessibility:
            return "Your Mac needs Accessibility so OpenBurnBar can drive clicks, keystrokes, and inspection for this agent."
        case .remoteDesktop:
            return "Your Mac needs Remote Desktop so OpenBurnBar can share the locked login screen with trusted devices."
        case .systemExtension:
            return "Your Mac needs the OpenBurnBar virtual keyboard bridge so Remote Unlock can type at the physical login screen."
        case .camera:
            return "Your Mac needs Camera access so OpenBurnBar can read the front-facing camera for this agent."
        case .microphone:
            return "Your Mac needs Microphone access so OpenBurnBar can capture audio for this agent."
        case .fullDiskAccess:
            return "Your Mac needs Full Disk Access so OpenBurnBar can reach this folder for the agent."
        case .automation:
            return "Your Mac needs Automation access so OpenBurnBar can drive the target app for this agent."
        }
    }
}
