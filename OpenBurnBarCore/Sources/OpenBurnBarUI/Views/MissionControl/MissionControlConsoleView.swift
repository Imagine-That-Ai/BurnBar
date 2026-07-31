import SwiftUI
import OpenBurnBarKernel

// MARK: - Mission Control Console (Root View)
//
// Layout:
//   • A slim header bar (title + live status line) spans the top.
//   • Regular width (≥860pt): two columns — composer left, live view right.
//   • Compact width (<860pt): single scroll — pending approvals first (they're
//     the most time-sensitive thing on the page), then the composer, then the
//     live view.
//
// State management:
//   • Host owns the live snapshot + dispatch / approval calls.
//   • Local view owns the *draft* (title, prompt, kind, runtime, depth, etc.).
//   • Forecast is recomputed reactively from draft + selected runtime.

@MainActor
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

    public var body: some View {
        GeometryReader { proxy in
            let isRegular = proxy.size.width >= 860
            VStack(spacing: 0) {
                headerBar

                if isRegular {
                    regularColumns
                } else {
                    compactScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UnifiedDesignSystem.Colors.background.ignoresSafeArea())
        }
        .task { await host.refresh() }
    }

    // MARK: Header

    private var headerBar: some View {
        MissionConsoleHeader(
            health: host.snapshot.health,
            activeMissionCount: host.snapshot.activeTiles.filter { $0.phase.isLive }.count,
            approvalPendingCount: host.snapshot.approvalAsks.count,
            blockedCount: host.snapshot.activeTiles.filter { $0.phase.isProblem }.count,
            onDismiss: onDismiss
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MissionChrome.hairlineColor)
                .frame(height: MissionChrome.hairline)
        }
    }

    // MARK: Layouts

    private var regularColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                composerColumn
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.xl)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .top)

            Rectangle()
                .fill(MissionChrome.hairlineColor)
                .frame(width: MissionChrome.hairline)

            ScrollView {
                situationColumn(includeApprovals: true)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 380, alignment: .top)
        }
    }

    private var compactScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
                if !host.snapshot.approvalAsks.isEmpty {
                    MissionApprovalsSection(
                        approvalAsks: host.snapshot.approvalAsks,
                        onApprove: { ask, approve in
                            Task { await host.respond(to: ask, approve: approve) }
                        }
                    )
                }

                composerColumn
                situationColumn(includeApprovals: false)
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.lg)
            .padding(.vertical, UnifiedDesignSystem.Spacing.lg)
            .padding(.bottom, UnifiedDesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Composer

    private var composerColumn: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
            MissionKindChooser(
                runtimes: host.snapshot.runtimes,
                selectedKind: kind,
                onSelect: { kind = $0 }
            )

            MissionRuntimePicker(
                runtimes: host.snapshot.runtimes,
                selectedRuntimeID: runtimeID,
                selectedKind: kind,
                onSelect: { runtimeID = $0 }
            )

            MissionTitlePromptFields(title: $title, prompt: $prompt)

            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                MissionDepthDial(depth: $depth)
                MissionApprovalLever(mode: $approvalMode)
                MissionPermissionsRow(
                    commandsAllowed: $commandsAllowed,
                    fileEditsAllowed: $fileEditsAllowed
                )
                MissionProjectField(
                    project: $targetProject,
                    knownProjects: host.snapshot.knownProjects,
                    recentProjects: host.snapshot.recentProjects
                )
            }

            MissionBurnForecastStrip(
                forecast: forecast,
                runtimeName: resolvedRuntime.displayName,
                runtimeAccent: runtimeAccent
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Live view

    private func situationColumn(includeApprovals: Bool) -> some View {
        MissionSituationRoom(
            activeTiles: host.snapshot.activeTiles,
            recentTicker: host.snapshot.recentTicker,
            approvalAsks: host.snapshot.approvalAsks,
            burnPerHourUSD: host.snapshot.health.burnPerHourUSD,
            burnTodayUSD: host.snapshot.health.burnTodayUSD,
            lastDispatchedMissionID: host.lastDispatchedMissionID,
            macOnline: host.snapshot.health.daemonState != .macOffline,
            includeApprovals: includeApprovals,
            onApprove: { ask, approve in
                Task { await host.respond(to: ask, approve: approve) }
            }
        )
    }

    // MARK: Derived state

    private var resolvedRuntime: MissionConsoleRuntime {
        if runtimeID == "auto" {
            // Base the forecast on the planner's first choice for this kind, so
            // the user sees a realistic preview.
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

    private var forecast: MissionConsoleForecast {
        MissionConsoleForecastComputer.forecast(for: dispatchRequest, runtime: resolvedRuntime)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.error)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dispatch failed")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
                Text(message)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { host.clearInlineError() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .fill(UnifiedDesignSystem.Colors.error.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                .strokeBorder(UnifiedDesignSystem.Colors.error.opacity(0.4), lineWidth: MissionChrome.hairline)
        }
    }
}
