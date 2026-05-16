import SwiftUI

// MARK: - Mission Control Console (Root View)
//
// Adaptive split layout:
//   • Regular width (≥860pt): two columns — composer left, situation room right.
//   • Compact width (<860pt): single column, composer on top, situation room below.
//
// State management:
//   • Host owns the live snapshot + dispatch / approval calls.
//   • Local view owns the *draft* (title, prompt, kind, runtime, depth, etc.).
//   • Forecast is recomputed reactively from draft + selected runtime.

public struct MissionControlConsoleView<Host: MissionConsoleHost>: View {
    @Bindable public var host: Host
    public let onDismiss: (() -> Void)?

    public init(host: Host, onDismiss: (() -> Void)? = nil) {
        self._host = Bindable(host)
        self.onDismiss = onDismiss
    }

    // Draft state
    @State private var title: String = ""
    @State private var prompt: String = ""
    @State private var kind: MissionConsoleKind = .diligence
    @State private var runtimeID: MissionConsoleRuntime.ID = "auto"
    @State private var depth: MissionConsoleDepth = .standard
    @State private var approvalMode: MissionConsoleApprovalMode = .existingPolicy
    @State private var commandsAllowed: Bool = false
    @State private var fileEditsAllowed: Bool = false
    @State private var targetProject: String = ""
    @State private var consoleAppeared = false

    public var body: some View {
        GeometryReader { proxy in
            let isRegular = proxy.size.width >= 860
            ZStack {
                backdrop
                if isRegular {
                    regularLayout
                } else {
                    compactLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(UnifiedDesignSystem.Colors.background.ignoresSafeArea())
        .task { await host.refresh() }
        .onChange(of: kind) { _, newKind in
            // When the user picks a new kind, auto-route AUTO to the first
            // preferred runtime so the constellation hints land on the right
            // tile without forcing the user to manually re-pick.
            if runtimeID == "auto" {
                // Keep AUTO selected — but pre-warm the forecast for the planner's
                // first choice.
                _ = newKind
            }
        }
        .opacity(consoleAppeared ? 1 : 0)
        .offset(y: consoleAppeared ? 0 : 6)
        .animation(UnifiedDesignSystem.Animation.gentle, value: consoleAppeared)
        .onAppear {
            consoleAppeared = true
        }
    }

    // MARK: Layouts

    private var regularLayout: some View {
        VStack(spacing: 0) {
            heroStrip

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    composerColumn
                        .padding(.horizontal, UnifiedDesignSystem.Spacing.xl)
                        .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .top)

                situationDivider

                ScrollView {
                    situationColumn
                        .padding(.horizontal, UnifiedDesignSystem.Spacing.xl)
                        .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 380, alignment: .top)
                .background(UnifiedDesignSystem.Colors.background)
            }
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
                heroStrip
                    .frame(maxWidth: .infinity, alignment: .leading)
                composerColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                situationColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            .padding(.bottom, UnifiedDesignSystem.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Pieces

    private var heroStrip: some View {
        MissionConsoleHero(
            health: host.snapshot.health,
            activeMissionCount: host.snapshot.activeTiles.filter { $0.phase.isLive }.count,
            approvalPendingCount: host.snapshot.approvalAsks.count,
            blockedCount: host.snapshot.activeTiles.filter { $0.phase.isProblem }.count,
            burnPerHourUSD: host.snapshot.health.burnPerHourUSD,
            hasCompletedSinceLastOpen: host.snapshot.activeTiles.contains { $0.phase == .completed },
            onDismiss: onDismiss
        )
        .background {
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.55))
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 1)
        }
    }

    private var composerColumn: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
            MissionKindChooser(
                runtimes: host.snapshot.runtimes,
                selectedKind: kind,
                onSelect: { kind = $0 }
            )

            MissionRuntimeConstellation(
                runtimes: host.snapshot.runtimes,
                selectedRuntimeID: runtimeID,
                selectedKind: kind,
                onSelect: { runtimeID = $0 }
            )

            MissionTitlePromptFields(title: $title, prompt: $prompt)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                    MissionDepthDial(depth: $depth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MissionApprovalLever(mode: $approvalMode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
                    MissionDepthDial(depth: $depth)
                    MissionApprovalLever(mode: $approvalMode)
                }
            }

            MissionPermissionsRow(
                commandsAllowed: $commandsAllowed,
                fileEditsAllowed: $fileEditsAllowed
            )

            MissionProjectField(
                project: $targetProject,
                knownProjects: host.snapshot.knownProjects,
                recentProjects: host.snapshot.recentProjects
            )

            if let error = host.inlineError {
                inlineErrorBanner(error)
            }

            MissionDispatchButton(
                runtimeAccent: runtimeAccent,
                runtimeName: resolvedRuntime.displayName,
                isEnabled: canDispatch,
                isDispatching: host.isDispatching,
                action: { dispatch() }
            )
        }
    }

    private var situationColumn: some View {
        MissionSituationRoom(
            activeTiles: host.snapshot.activeTiles,
            recentTicker: host.snapshot.recentTicker,
            approvalAsks: host.snapshot.approvalAsks,
            burnPerHourUSD: host.snapshot.health.burnPerHourUSD,
            burnTodayUSD: host.snapshot.health.burnTodayUSD,
            lastDispatchedMissionID: host.lastDispatchedMissionID,
            macOnline: host.snapshot.health.daemonState != .macOffline,
            onApprove: { ask, approve in
                Task { await host.respond(to: ask, approve: approve) }
            }
        )
    }

    private var situationDivider: some View {
        Rectangle()
            .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
            .frame(width: 1)
            .ignoresSafeArea(edges: .vertical)
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            UnifiedDesignSystem.Colors.background
            // Soft ember glow in the top-left for atmosphere — does not compete
            // with content, just keeps the canvas alive.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [UnifiedDesignSystem.Colors.ember.opacity(0.10), Color.clear],
                        center: .center, startRadius: 0, endRadius: 320
                    )
                )
                .frame(width: 600, height: 600)
                .offset(x: -180, y: -220)
                .blur(radius: 30)
                .blendMode(.plusLighter)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [UnifiedDesignSystem.Colors.hermesAureate.opacity(0.10), Color.clear],
                        center: .center, startRadius: 0, endRadius: 240
                    )
                )
                .frame(width: 460, height: 460)
                .offset(x: 220, y: 220)
                .blur(radius: 24)
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Derived state

    private var resolvedRuntime: MissionConsoleRuntime {
        if runtimeID == "auto" {
            // Use AUTO's preview runtime — but base the forecast on the planner's
            // first choice for this kind, so the user sees a realistic preview.
            if let preferredID = kind.preferredRuntimes.first,
               let preferred = host.snapshot.runtimes.first(where: { $0.id == preferredID }) {
                return preferred
            }
            return .auto
        }
        return host.snapshot.runtimes.first(where: { $0.id == runtimeID }) ?? .auto
    }

    private var runtimeAccent: Color {
        if runtimeID == "auto" {
            return UnifiedDesignSystem.Colors.ember
        }
        return UnifiedDesignSystem.Colors.primary(for: resolvedRuntime.provider)
    }

    private var canDispatch: Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedPrompt.isEmpty && !host.isDispatching
    }

    private var dispatchRequest: MissionConsoleDispatchRequest {
        MissionConsoleDispatchRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            runtimeID: runtimeID,
            targetProject: targetProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : targetProject.trimmingCharacters(in: .whitespacesAndNewlines),
            depth: depth,
            approvalMode: approvalMode,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )
    }

    private func dispatch() {
        Task {
            let outcome = await host.dispatch(dispatchRequest)
            if case .dispatched = outcome {
                // Clear the draft so the next mission starts fresh.
                await MainActor.run {
                    withAnimation(UnifiedDesignSystem.Animation.gentle) {
                        title = ""
                        prompt = ""
                    }
                }
            }
        }
    }

    // MARK: Inline error banner

    private func inlineErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dispatch failed")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
                Text(message)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { host.clearInlineError() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(UnifiedDesignSystem.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.error.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.error.opacity(0.45), lineWidth: 0.6)
        }
    }
}
