import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Settings → Media & Sharing

/// Settings → **Media & Sharing** — one-page surface that frames every
/// permission OpenBurnBar needs in terms of *what it unlocks*, not the raw
/// macOS permission name.
///
/// The screen replaces the prior three-row "Mercury" list. The premise is
/// unchanged (camera / microphone / screen recording are still the
/// permissions in play) but each one is shown alongside the capability it
/// enables — Screen share, Voice calls, Video calls — and the primary
/// button does the most useful thing for the current status: prompt
/// in-app where possible, deep-link into System Settings otherwise.
@MainActor
struct MediaPermissionsView: View {
    @State private var screen: PermissionStatus = .notRequested
    @State private var camera: PermissionStatus = .notRequested
    @State private var mic: PermissionStatus = .notRequested
    @State private var isRequestingCamera = false
    @State private var isRequestingMic = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                screenShareCard
                voiceCallCard
                videoCallCard
                privacyFooter
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Media & Sharing")
        .task { await refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // System Settings changes don't notify us — re-poll when the
            // user comes back to the app so the badges update.
            Task { await refreshAll() }
        }
    }

    // MARK: - Header

    private var header: some View {
        Text("Talk to your paired iPhone or iPad — screen share, voice and video calls, file transfer. OpenBurnBar only uses these permissions during sessions you start, and bytes go peer-to-peer over iroh. Nothing routes through our servers.")
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .id(SettingsAnchor.mediaPermissions)
    }

    // MARK: - Capability cards

    private var screenShareCard: some View {
        CapabilityCard(
            title: "Screen share",
            iconName: "rectangle.on.rectangle.angled.fill",
            iconTint: DesignSystem.Colors.hermesMercury,
            blurb: "Mirror this Mac on your paired iPhone or iPad while you pair-debug.",
            requirements: [
                PermissionRequirement(
                    label: "Screen Recording",
                    status: screen,
                    isInflight: false
                )
            ],
            actionTitle: screenActionTitle,
            actionStyle: screen == .allowed ? .none : .prominent,
            onAction: openScreenRecordingSettings
        )
    }

    private var voiceCallCard: some View {
        CapabilityCard(
            title: "Voice calls",
            iconName: "phone.fill",
            iconTint: DesignSystem.Colors.teal,
            blurb: "Talk to your paired iPhone using your Mac's microphone.",
            requirements: [
                PermissionRequirement(
                    label: "Microphone",
                    status: mic,
                    isInflight: isRequestingMic
                )
            ],
            actionTitle: actionTitleForAVStatus(mic, allowedTitle: nil, denyTitle: "Open System Settings", promptTitle: "Allow microphone access"),
            actionStyle: mic == .allowed ? .none : .prominent,
            onAction: { Task { await requestMicAccess() } }
        )
    }

    private var videoCallCard: some View {
        CapabilityCard(
            title: "Video calls",
            iconName: "video.fill",
            iconTint: DesignSystem.Colors.ember,
            blurb: "Two-way video with your paired iPhone. Microphone + camera together.",
            requirements: [
                PermissionRequirement(
                    label: "Microphone",
                    status: mic,
                    isInflight: isRequestingMic
                ),
                PermissionRequirement(
                    label: "Camera",
                    status: camera,
                    isInflight: isRequestingCamera
                ),
            ],
            actionTitle: videoActionTitle,
            actionStyle: (mic == .allowed && camera == .allowed) ? .none : .prominent,
            onAction: { Task { await requestVideoAccess() } }
        )
    }

    // MARK: - Footer

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.success)
            VStack(alignment: .leading, spacing: 4) {
                Text("Files don't need a system permission")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Sending or receiving files is always you-initiated — you pick what to share each time, so OpenBurnBar never asks macOS for a blanket grant.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.success.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.success.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Action title helpers

    private var screenActionTitle: String {
        switch screen {
        case .allowed: return ""
        case .denied: return "Open System Settings"
        case .notRequested: return "Open System Settings"
        }
    }

    private var videoActionTitle: String {
        let needsMic = mic != .allowed
        let needsCam = camera != .allowed
        guard needsMic || needsCam else { return "" }
        // If either has been denied, we can't re-prompt — kick the user
        // out to System Settings so they can flip the switch manually.
        if mic == .denied || camera == .denied {
            return "Open System Settings"
        }
        if needsMic && needsCam { return "Allow microphone & camera" }
        if needsMic { return "Allow microphone access" }
        return "Allow camera access"
    }

    private func actionTitleForAVStatus(
        _ status: PermissionStatus,
        allowedTitle: String?,
        denyTitle: String,
        promptTitle: String
    ) -> String {
        switch status {
        case .allowed: return allowedTitle ?? ""
        case .denied: return denyTitle
        case .notRequested: return promptTitle
        }
    }

    // MARK: - Permission requests

    private func openScreenRecordingSettings() {
        // Asking for screen recording is a one-way trip to System Settings;
        // macOS does not expose a programmatic prompt.
        #if canImport(CoreGraphics)
        _ = CGRequestScreenCaptureAccess()
        #endif
        openSystemSettings(deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func requestMicAccess() async {
        if mic == .denied {
            openSystemSettings(deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }
        #if canImport(AVFoundation)
        isRequestingMic = true
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        isRequestingMic = false
        mic = granted ? .allowed : .denied
        #endif
    }

    private func requestCameraAccess() async {
        if camera == .denied {
            openSystemSettings(deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            return
        }
        #if canImport(AVFoundation)
        isRequestingCamera = true
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
        }
        isRequestingCamera = false
        camera = granted ? .allowed : .denied
        #endif
    }

    private func requestVideoAccess() async {
        // If either has been denied, only System Settings can flip it back.
        if mic == .denied || camera == .denied {
            openSystemSettings(deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            return
        }
        // Otherwise prompt for whichever isn't yet granted. Microphone
        // first so the OS dialogs don't both fire on top of each other.
        if mic != .allowed { await requestMicAccess() }
        if camera != .allowed { await requestCameraAccess() }
    }

    private func openSystemSettings(deepLink: String) {
        #if canImport(AppKit)
        if let url = URL(string: deepLink) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Status query

    private func refreshAll() async {
        camera = await currentAVPermissionStatus(for: .video)
        mic = await currentAVPermissionStatus(for: .audio)
        screen = currentScreenRecordingStatus()
    }

    private func currentAVPermissionStatus(for mediaType: AVMediaType) async -> PermissionStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
        #else
        return .notRequested
        #endif
    }

    /// Screen Recording status. macOS doesn't expose a queryable API outside
    /// 14.5+ private symbols, so `CGPreflightScreenCaptureAccess` is our best
    /// signal — it returns true once the user has granted access in System
    /// Settings, and false otherwise (whether they've denied or simply
    /// haven't decided). We can't distinguish "denied" from "not requested"
    /// reliably, so we collapse both into `.notRequested`.
    private func currentScreenRecordingStatus() -> PermissionStatus {
        #if canImport(CoreGraphics)
        return CGPreflightScreenCaptureAccess() ? .allowed : .notRequested
        #else
        return .notRequested
        #endif
    }
}

// MARK: - Capability card

private struct CapabilityCard: View {
    enum ActionStyle { case prominent, none }

    let title: String
    let iconName: String
    let iconTint: Color
    let blurb: String
    let requirements: [PermissionRequirement]
    let actionTitle: String
    let actionStyle: ActionStyle
    let onAction: () -> Void

    private var isReady: Bool {
        requirements.allSatisfy { $0.status == .allowed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(iconTint.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(blurb)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DesignSystem.Spacing.sm)
                if isReady {
                    readyBadge
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(requirements) { req in
                    PermissionPill(requirement: req)
                }
                Spacer(minLength: DesignSystem.Spacing.sm)
                if actionStyle == .prominent && !actionTitle.isEmpty {
                    Button(action: onAction) {
                        Text(actionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var readyBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Ready")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(DesignSystem.Colors.success)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(DesignSystem.Colors.success.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Permission pill

private struct PermissionRequirement: Identifiable, Hashable {
    let label: String
    let status: PermissionStatus
    let isInflight: Bool
    var id: String { label }
}

private struct PermissionPill: View {
    let requirement: PermissionRequirement

    var body: some View {
        let tint = requirement.status.tint
        HStack(spacing: 4) {
            if requirement.isInflight {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: requirement.status.icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text("\(requirement.label) · \(requirement.status.shortLabel)")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel("\(requirement.label) permission: \(requirement.status.shortLabel)")
    }
}

// MARK: - Permission status

enum PermissionStatus: Sendable, Hashable {
    case allowed
    case denied
    case notRequested

    /// Legacy label kept for backward compatibility with any callsite that
    /// reads `.label`. New UI consumes `shortLabel` to keep chips compact.
    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .notRequested: return "Not requested"
        }
    }

    var shortLabel: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .notRequested: return "Needs access"
        }
    }

    var icon: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .notRequested: return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: return DesignSystem.Colors.success
        case .denied: return DesignSystem.Colors.error
        case .notRequested: return DesignSystem.Colors.amber
        }
    }
}
