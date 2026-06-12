import SwiftUI
import OpenBurnBarCore

// MARK: - CLI Agent Resume / Handoff Sheet (iOS / iPadOS)
//
// The premium surface for restarting a mirrored CLI session on the paired
// Mac. A user picks a target provider, sees up-front whether it will be a
// Native resume or a Handoff package, taps once, and watches the session
// travel device → Mac as a small package chip that resolves into a status
// pill. The relay/daemon response is the source of truth; this view owns
// only transient UI state.
//
// Layout adapts: a compact action sheet on iPhone (`.medium`/`.large`
// detents) and a wider, centered inspector treatment on iPad.

// MARK: Flow model

@MainActor
@Observable
final class CLIAgentResumeFlowModel {

    enum Phase: Equatable {
        case picking
        case sending
        case finished(CLIAgentResumeOutcome)
    }

    let session: CLIAgentSessionRecord
    /// The session's own provider as a resume target, when it is one of the
    /// first-class targets (`nil` for handoff-only origins like OpenClaw).
    let homeTarget: CLIAgentResumeTarget?
    /// Currently selected destination. `nil` means "the session's own
    /// provider" — i.e. a plain Resume on Mac.
    private(set) var selectedTarget: CLIAgentResumeTarget?
    private(set) var phase: Phase = .picking
    private(set) var lastAction: CLIAgentSessionActionKind = .resume

    private let transport: CLIAgentRelayChatTransporting

    init(
        session: CLIAgentSessionRecord,
        transport: CLIAgentRelayChatTransporting = CLIAgentRelayChatTransport.shared
    ) {
        self.session = session
        self.transport = transport
        let home = session.agent.resumeTarget
        self.homeTarget = home
        self.selectedTarget = home
    }

    // MARK: Derived UI state

    var isSending: Bool { if case .sending = phase { return true }; return false }

    var outcome: CLIAgentResumeOutcome? {
        if case let .finished(value) = phase { return value }
        return nil
    }

    /// `true` when the chosen destination is the session's own provider, so
    /// the primary action is an in-place resume rather than a cross-provider
    /// handoff.
    var isSameProvider: Bool {
        selectedTarget == nil || selectedTarget == homeTarget
    }

    /// Capability of the action the primary button will perform right now.
    var primaryCapability: CLIAgentResumeCapability {
        if isSameProvider {
            return session.agent.supportsNativeResume ? .native : .handoff
        }
        return selectedTarget?.capability ?? .handoff
    }

    var primaryActionTitle: String {
        if isSameProvider { return "Resume on Mac" }
        return "Resume in \(selectedTarget?.displayName ?? "…")"
    }

    /// Brand color of the current destination.
    var destinationBrandColor: Color {
        if let selectedTarget {
            return Color(hex: selectedTarget.brandHex)
        }
        return homeTarget.map { Color(hex: $0.brandHex) } ?? MobileTheme.Colors.accent
    }

    var destinationProvider: AgentProvider {
        selectedTarget?.agentProvider
            ?? homeTarget?.agentProvider
            ?? session.agent.assistantRuntime.agentProvider
    }

    var homeProvider: AgentProvider {
        session.agent.assistantRuntime.agentProvider
    }

    var subtitle: String {
        [session.agent.displayName, session.modelName ?? "", session.workspaceLabel ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: Intents

    func select(_ target: CLIAgentResumeTarget) {
        guard !isSending else { return }
        HapticBus.chipChange()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            selectedTarget = target
            if case .finished = phase { phase = .picking }
        }
    }

    func resume() async { await perform(isSameProvider ? .resume : .handoff) }
    func openPackage() async { await perform(.packageOnly) }
    func retry() async { await perform(lastAction) }

    func resetToPicking() {
        guard !isSending else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            phase = .picking
        }
    }

    private func perform(_ action: CLIAgentSessionActionKind) async {
        guard !isSending else { return }
        lastAction = action
        let requestedTarget = selectedTarget ?? homeTarget
        HapticBus.primaryAction()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
            phase = .sending
        }

        let request = CLIAgentSessionActionRequest(
            sessionID: session.resumeLookupID,
            action: action,
            targetRuntime: isSameProvider ? nil : selectedTarget?.wireID,
            targetModelID: nil,
            presentationMode: action == .packageOnly ? .macVisibleCLI : .macInteractiveCLI
        )

        let resolved: CLIAgentResumeOutcome
        do {
            let response = try await transport.performSessionAction(request)
            resolved = CLIAgentResumeOutcome(
                response: response,
                requestedTargetDisplayName: requestedTarget?.displayName
            )
        } catch {
            let synthetic = CLIAgentSessionActionResponse(
                status: .error,
                errorRecovery: error.localizedDescription
            )
            resolved = CLIAgentResumeOutcome(
                response: synthetic,
                requestedTargetDisplayName: requestedTarget?.displayName
            )
        }

        if resolved.isSuccess { HapticBus.milestone() } else { HapticBus.threshold() }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            phase = .finished(resolved)
        }
    }
}

// MARK: Sheet

struct CLIAgentResumeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: CLIAgentResumeFlowModel

    init(session: CLIAgentSessionRecord) {
        _model = State(initialValue: CLIAgentResumeFlowModel(session: session))
    }

    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.lg) {
                header
                ResumeBridgeView(
                    homeProvider: model.homeProvider,
                    destinationProvider: model.destinationProvider,
                    brandColor: model.destinationBrandColor,
                    phase: model.phase
                )
                .frame(maxWidth: 460)

                if model.isSending {
                    sendingCaption
                } else if let outcome = model.outcome {
                    outcomeArea(outcome)
                } else {
                    pickerSection
                    primaryActions
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.top, MobileTheme.Spacing.lg)
            .padding(.bottom, MobileTheme.Spacing.xl)
            .frame(maxWidth: isWide ? 640 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(isWide ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .resumeSheetBackground()
        .presentationCornerRadius(28)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(model.destinationBrandColor.opacity(0.16))
                    .frame(width: 52, height: 52)
                UnifiedProviderLogoView(provider: model.homeProvider, size: 32)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Restart session")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text(model.session.title)
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(2)
                Text(model.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Picker

    private var pickerSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack {
                Text("Resume in…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                CapabilityLegend()
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: MobileTheme.Spacing.sm),
                    count: isWide ? 3 : 2
                ),
                spacing: MobileTheme.Spacing.sm
            ) {
                ForEach(CLIAgentResumeTarget.allCases) { target in
                    ResumeTargetChip(
                        target: target,
                        isSelected: model.selectedTarget == target,
                        isHome: model.homeTarget == target
                    ) {
                        model.select(target)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: Primary actions

    private var primaryActions: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: model.primaryCapability.systemImageName)
                Text(model.primaryCapability == .native
                     ? "Continues this session in place."
                     : "Opens a Mac-local handoff package.")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await model.resume() }
            } label: {
                Text(model.primaryActionTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                            .fill(model.destinationBrandColor)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: model.destinationBrandColor.opacity(0.4), radius: 12, y: 6)
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.openPackage() }
            } label: {
                Label("Package", systemImage: "doc.zipper")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .fill(model.destinationBrandColor.opacity(0.14))
                    )
                    .foregroundStyle(model.destinationBrandColor)
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity)
    }

    // MARK: Sending

    private var sendingCaption: some View {
        VStack(spacing: 6) {
            Text("Sending to your Mac…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(model.primaryActionTitle)
                .font(.system(size: 12))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .transition(.opacity)
    }

    // MARK: Outcome

    @ViewBuilder
    private func outcomeArea(_ outcome: CLIAgentResumeOutcome) -> some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            if let detail = outcome.detail {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let recovery = outcome.recovery {
                Text(recovery)
                    .font(.system(size: 13))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
                if !outcome.isSuccess {
                    Button {
                        Task { await model.retry() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                    .fill(model.destinationBrandColor)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        model.resetToPicking()
                    } label: {
                        Text("Resume again")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                    .fill(model.destinationBrandColor.opacity(0.16))
                            )
                            .foregroundStyle(model.destinationBrandColor)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                .fill(MobileTheme.Colors.surfaceElevated)
                        )
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: Capability legend

private struct CapabilityLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legend(.native)
            legend(.handoff)
        }
    }

    private func legend(_ capability: CLIAgentResumeCapability) -> some View {
        HStack(spacing: 3) {
            Image(systemName: capability.systemImageName)
                .font(.system(size: 8, weight: .bold))
            Text(capability.label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(MobileTheme.Colors.textMuted)
    }
}

// MARK: Capability badge

struct CLIResumeCapabilityBadge: View {
    let capability: CLIAgentResumeCapability
    let brand: Color

    var body: some View {
        let isNative = capability == .native
        let tint = isNative ? brand : Color.secondary
        Label(capability.label, systemImage: capability.systemImageName)
            .font(.system(size: 9, weight: .bold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }
}

// MARK: Target chip

struct ResumeTargetChip: View {
    let target: CLIAgentResumeTarget
    let isSelected: Bool
    let isHome: Bool
    let action: () -> Void

    var body: some View {
        let brand = Color(hex: target.brandHex)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    UnifiedProviderLogoView(provider: target.agentProvider, size: 26)
                    Text(target.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(brand)
                    }
                }
                HStack(spacing: 6) {
                    CLIResumeCapabilityBadge(capability: target.capability, brand: brand)
                    if isHome {
                        Text("This session")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(brand.opacity(isSelected ? 0.16 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .strokeBorder(brand.opacity(isSelected ? 0.9 : 0.18), lineWidth: isSelected ? 1.6 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(target.displayName), \(target.capability.label) resume")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: Bridge (device → Mac motion)

struct ResumeBridgeView: View {
    let homeProvider: AgentProvider
    let destinationProvider: AgentProvider
    let brandColor: Color
    let phase: CLIAgentResumeFlowModel.Phase

    @State private var pulse = false

    private let nodeSize: CGFloat = 48
    private let chipSize: CGFloat = 34

    private var isSending: Bool { if case .sending = phase { return true }; return false }
    private var finishedOutcome: CLIAgentResumeOutcome? {
        if case let .finished(value) = phase { return value }
        return nil
    }
    private var hasMoved: Bool { isSending || finishedOutcome != nil }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(width - nodeSize, 0)

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                brandColor.opacity(hasMoved ? 0.55 : 0.22),
                                brandColor.opacity(0.12)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(travel, 0), height: 4)
                    .offset(x: nodeSize / 2)

                // Device node (origin)
                bridgeNode(provider: homeProvider, glyph: "iphone")
                    .offset(x: 0)

                // Mac node (destination)
                bridgeNode(provider: destinationProvider, glyph: "laptopcomputer", showProvider: true)
                    .offset(x: travel)

                // Traveling package chip
                packageChip
                    .scaleEffect(pulse && isSending ? 1.08 : 1.0)
                    .offset(x: hasMoved ? travel + (nodeSize - chipSize) / 2 : (nodeSize - chipSize) / 2)
                    .opacity(isSending ? 1 : 0)

                // Resolved status pill at the Mac
                if let outcome = finishedOutcome {
                    statusPill(outcome)
                        .offset(x: 0)
                        .frame(width: width, alignment: .center)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: width, height: nodeSize)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 72)
        .onChange(of: isSending) { _, sending in
            pulse = sending
        }
        .onAppear { pulse = isSending }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
    }

    private func bridgeNode(provider: AgentProvider, glyph: String, showProvider: Bool = false) -> some View {
        ZStack {
            Circle()
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(Circle().strokeBorder(brandColor.opacity(0.3), lineWidth: 1))
                .frame(width: nodeSize, height: nodeSize)
            if showProvider {
                UnifiedProviderLogoView(provider: provider, size: 26)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
    }

    private var packageChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(brandColor)
                .frame(width: chipSize, height: chipSize)
                .shadow(color: brandColor.opacity(0.5), radius: 8, y: 3)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func statusPill(_ outcome: CLIAgentResumeOutcome) -> some View {
        let tint = outcome.isSuccess ? brandColor : MobileTheme.Colors.error
        return HStack(spacing: 7) {
            Image(systemName: outcome.status.presentation.systemImageName)
                .font(.system(size: 13, weight: .bold))
            Text(outcome.status.presentation.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(tint))
        .shadow(color: tint.opacity(0.45), radius: 10, y: 4)
    }
}

private extension View {
    /// Owns the sheet background on every OS. On iOS 26 the system sheet
    /// background is Liquid Glass — no opaque fill is allowed on top of it,
    /// only a translucent theme wash, so the glass stays visible and can
    /// sample the content behind the sheet (including at the `.medium`
    /// detent). Older systems keep the original opaque theme fill under the
    /// thin-material presentation background.
    @ViewBuilder
    func resumeSheetBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.background(
                MobileTheme.Colors.background.opacity(0.3).ignoresSafeArea()
            )
        } else {
            self
                .background(MobileTheme.Colors.background.ignoresSafeArea())
                .presentationBackground(.thinMaterial)
        }
    }
}
