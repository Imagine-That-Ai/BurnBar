#if canImport(AppKit) && !DISTRIBUTION_MAS
import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import OpenBurnBarComputerUseCore

/// Phase 14 — Step-by-step Mac permissions wizard. Walks the user
/// through every TCC bucket the agent uses, firing the native prompt,
/// opening System Settings to the exact pane, watching TCC for the
/// granted transition, and auto-advancing the moment macOS flips.
///
/// Skippable per-bucket; the user can also bail out of the whole flow.
/// Everything deferred lands in `SettingsManager.systemPermissionsDeferredKinds`
/// so the chat-side pill knows to surface the same examples mid-session.
struct OnboardingSystemPermissionsView: View {
    @ObservedObject var coordinator: PermissionsOnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            cardContent
            Spacer(minLength: 0)
            stepDots
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { coordinator.start() }
        .onDisappear { coordinator.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("MAC PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("Let the agent actually help you")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Each permission unlocks a different ability. Allow now, see exactly what's blocked if you skip, and finish the rest later from chat.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if let step = coordinator.currentStep {
            PermissionsCard(step: step, coordinator: coordinator)
                .id(step.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                         removal: .move(edge: .leading).combined(with: .opacity)))
        } else {
            allDoneCard
        }
    }

    private var allDoneCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Mac permissions: done")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Anything you skipped will surface as an inline pill the first time it's needed in chat. You can revisit this from Settings → Computer Use.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(coordinator.steps.enumerated()), id: \.element.id) { index, step in
                Circle()
                    .fill(dotColor(for: step, isCurrent: index == coordinator.currentIndex))
                    .frame(width: 6, height: 6)
            }
            Spacer()
            Text(coordinator.progressLabel)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func dotColor(for step: PermissionsOnboardingCoordinator.Step,
                          isCurrent: Bool) -> Color {
        switch coordinator.resolution(for: step) {
        case .granted: return DesignSystem.Colors.success
        case .deferred: return DesignSystem.Colors.textMuted
        case .pending:
            return isCurrent ? DesignSystem.Colors.coral : DesignSystem.Colors.borderSubtle
        }
    }
}

// MARK: - Card

private struct PermissionsCard: View {
    let step: PermissionsOnboardingCoordinator.Step
    @ObservedObject var coordinator: PermissionsOnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            heroRow
            Divider().opacity(0.35)
            Text("Without this, the agent can't…")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(step.kind.onboardingDenialExamples, id: \.self) { example in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.error.opacity(0.85))
                        Text(example)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                }
            }
            statusRow
            controls
            if let extra = step.bundleId {
                Text("Targeting \(step.targetDisplayName) (\(extra)). Automation appears in System Settings under OpenBurnBar, with one toggle for each app.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var heroRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(hex: "C8BFB5"), Color(hex: "A2ACBA")],
                                          startPoint: .topLeading,
                                          endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: step.kind.sfSymbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.titleForCard)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(step.kind.onboardingCapabilitySummary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        let status = coordinator.liveStatus(for: step)
        return HStack(spacing: 4) {
            Image(systemName: status.glyph)
                .font(.system(size: 10, weight: .semibold))
            Text(status.label)
                .font(DesignSystem.Typography.monoTiny)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.12), in: Capsule())
    }

    private var statusRow: some View {
        let liveStatus = coordinator.liveStatus(for: step)
        let summary: String
        switch liveStatus {
        case .granted:
            summary = "Granted. Auto-advancing…"
        case .needsAccess, .unknown, .timeout:
            if step.kind == .automation {
                summary = "Click Request Access. If macOS does not show a prompt, open Automation and enable \(step.targetDisplayName) under OpenBurnBar."
            } else {
                summary = "Allow on your Mac. We'll trigger the system prompt and open System Settings for you."
            }
        case .requesting:
            summary = "Watching for the system prompt…"
        case .denied:
            if step.kind == .automation {
                summary = "Denied. Open Automation, expand OpenBurnBar, and enable \(step.targetDisplayName)."
            } else {
                summary = "Denied. You can still toggle it manually in System Settings."
            }
        }
        return Text(summary)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private var controls: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                Task { await coordinator.requestCurrent() }
            } label: {
                Text(primaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: step.kind == .automation ? 112 : 140)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.liveStatus(for: step) == .granted)

            Button {
                coordinator.skipCurrent()
            } label: {
                Text("Skip for now")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                coordinator.openSystemSettings(for: step)
            } label: {
                Label(settingsLabel, systemImage: "gear")
                    .font(DesignSystem.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var primaryLabel: String {
        switch coordinator.liveStatus(for: step) {
        case .granted: return "Granted"
        case .requesting: return "Watching…"
        default:
            switch step.kind {
            case .camera, .microphone: return "Allow now"
            case .screenRecording, .accessibility: return "Prompt and open Settings"
            case .fullDiskAccess: return "Open Settings"
            case .automation: return "Request Access"
            }
        }
    }

    private var settingsLabel: String {
        step.kind == .automation ? "Open Automation" : "Open System Settings"
    }
}

// MARK: - Coordinator

/// Drives the wizard: builds the ordered step list, runs the live
/// snapshot poll, fires native prompts, opens System Settings, and
/// advances when TCC reports `granted`.
@MainActor
final class PermissionsOnboardingCoordinator: ObservableObject {
    struct Step: Identifiable, Hashable {
        let id: String
        let kind: SystemPermissionKind
        let bundleId: String?
        let titleForCard: String

        var targetDisplayName: String {
            guard let bundleId else { return kind.displayTitle }
            return OnboardingAutomationTargets.target(bundleId: bundleId)?.displayName ?? bundleId
        }
    }

    enum Resolution { case pending, granted, deferred }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private var snapshotByKey: [String: SystemPermissionStatus] = [:]
    @Published private var deferredKeys: Set<String> = []

    private var pollTask: Task<Void, Never>?

    init() {
        var ordered: [Step] = [
            Step(id: "microphone", kind: .microphone, bundleId: nil, titleForCard: "Microphone"),
            Step(id: "camera", kind: .camera, bundleId: nil, titleForCard: "Camera"),
            Step(id: "screen", kind: .screenRecording, bundleId: nil, titleForCard: "Screen Recording"),
            Step(id: "accessibility", kind: .accessibility, bundleId: nil, titleForCard: "Accessibility"),
            Step(id: "fda", kind: .fullDiskAccess, bundleId: nil, titleForCard: "Full Disk Access")
        ]
        for target in OnboardingAutomationTargets.preflightTargets {
            ordered.append(
                Step(
                    id: "automation:\(target.bundleId)",
                    kind: .automation,
                    bundleId: target.bundleId,
                    titleForCard: "Automation — \(target.displayName)"
                )
            )
        }
        self.steps = ordered
    }

    var currentStep: Step? {
        guard currentIndex < steps.count else { return nil }
        return steps[currentIndex]
    }

    var progressLabel: String {
        if steps.isEmpty { return "" }
        let position = min(currentIndex + 1, steps.count)
        return String(format: "%02d / %02d", position, steps.count)
    }

    var allResolved: Bool { currentIndex >= steps.count }

    func resolution(for step: Step) -> Resolution {
        if deferredKeys.contains(step.id) { return .deferred }
        if liveStatus(for: step) == .granted { return .granted }
        return .pending
    }

    func liveStatus(for step: Step) -> SystemPermissionStatus {
        snapshotByKey["\(step.kind.rawValue)|\(step.bundleId ?? "")"] ?? .needsAccess
    }

    func start() {
        SystemPermissionMonitor.shared.start(pollInterval: 1.0)
        for step in steps where step.kind == .automation {
            if let bundleId = step.bundleId {
                SystemPermissionMonitor.shared.trackAutomation(bundleId: bundleId)
            }
        }
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await SystemPermissionMonitor.shared.refreshNow(emitting: true)
                self?.refreshSnapshots()
                self?.advanceIfGranted()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func requestCurrent() async {
        guard let step = currentStep else { return }
        switch step.kind {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            #if canImport(CoreGraphics)
            _ = CGRequestScreenCaptureAccess()
            #endif
            openSystemSettings(for: step)
        case .accessibility:
            _ = MacAccessibilityPermissionRequester.promptAndOpenSettings()
        case .fullDiskAccess:
            openSystemSettings(for: step)
        case .automation:
            if let bundleId = step.bundleId {
                triggerAutomationPrompt(bundleId: bundleId)
            }
        }
        await SystemPermissionMonitor.shared.refreshNow(emitting: true)
        refreshSnapshots()
    }

    func skipCurrent() {
        guard let step = currentStep else { return }
        deferredKeys.insert(step.id)
        advance()
    }

    /// Clear any deferred-bucket marks and rewind to the first
    /// unresolved step so the user can re-attempt grants they
    /// previously skipped. Used by the Settings → Computer Use
    /// "Re-run Mac Permissions Setup" entry.
    func resetDeferrals() {
        deferredKeys.removeAll()
        refreshSnapshots()
        if let firstUngranted = steps.firstIndex(where: { liveStatus(for: $0) != .granted }) {
            currentIndex = firstUngranted
        } else {
            currentIndex = 0
        }
    }

    func openSystemSettings(for step: Step) {
        guard let link = step.kind.systemSettingsDeepLink, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func deferredKinds() -> Set<String> {
        Set(deferredKeys.compactMap { id -> String? in
            guard let step = steps.first(where: { $0.id == id }) else { return nil }
            if let bundleId = step.bundleId {
                return "\(step.kind.rawValue):\(bundleId)"
            }
            return step.kind.rawValue
        })
    }

    // MARK: - Private

    private func refreshSnapshots() {
        var next: [String: SystemPermissionStatus] = [:]
        for snapshot in SystemPermissionMonitor.shared.snapshots.values {
            let key = "\(snapshot.kind.rawValue)|\(snapshot.bundleId ?? "")"
            next[key] = snapshot.status
        }
        snapshotByKey = next
    }

    private func advanceIfGranted() {
        guard let step = currentStep else { return }
        if liveStatus(for: step) == .granted { advance() }
    }

    private func advance() {
        guard currentIndex < steps.count else { return }
        withAnimation(DesignSystem.Animation.gentle) {
            currentIndex += 1
        }
    }

    private func triggerAutomationPrompt(bundleId: String) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil || bundleId == "com.apple.finder" else {
            openSystemSettings(for: Step(id: "automation:\(bundleId)", kind: .automation, bundleId: bundleId, titleForCard: "Automation"))
            return
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, true)
        runAutomationProbe(bundleId: bundleId)
    }

    private func runAutomationProbe(bundleId: String) {
        let escapedBundleId = bundleId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application id \"\(escapedBundleId)\" to get name"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

enum OnboardingAutomationTargets {
    struct Target {
        let bundleId: String
        let displayName: String
    }

    static let preflightTargets: [Target] = [
        Target(bundleId: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
        Target(bundleId: "com.apple.Safari", displayName: "Safari"),
        Target(bundleId: "com.google.Chrome", displayName: "Google Chrome"),
        Target(bundleId: "com.apple.finder", displayName: "Finder"),
        Target(bundleId: "com.apple.Notes", displayName: "Notes")
    ]

    static func target(bundleId: String) -> Target? {
        preflightTargets.first { $0.bundleId == bundleId }
    }
}

// MARK: - Status helpers

private extension SystemPermissionStatus {
    var glyph: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .needsAccess, .unknown, .timeout: return "lock.fill"
        case .requesting: return "hourglass"
        case .denied: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .granted: return "ON"
        case .needsAccess: return "OFF"
        case .unknown: return "?"
        case .requesting: return "…"
        case .denied: return "DENIED"
        case .timeout: return "—"
        }
    }

    var color: Color {
        switch self {
        case .granted: return DesignSystem.Colors.success
        case .denied: return DesignSystem.Colors.error
        case .requesting: return DesignSystem.Colors.coral
        default: return DesignSystem.Colors.textMuted
        }
    }
}
#endif
