#if canImport(SwiftUI) && canImport(AppKit) && !DISTRIBUTION_MAS
import SwiftUI
import AppKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// First-run setup wizard for Computer Use Path C (Mac System).
/// Three screens (Decision: master plan § B.5 setup):
///
///   1. **Overview.** What Computer Use does, what's about to happen.
///   2. **Permissions.** Trigger the macOS Accessibility prompt and
///      surface the Playwright install flow if Phase 9 is enabled.
///   3. **Sample action.** "OpenBurnBar will open Calculator and
///      compute 2+2" — a benign, observable smoke test that proves the
///      whole approval flow before the agent is allowed to drive
///      anything real.
///
/// `#if !DISTRIBUTION_MAS` — Path C requires Accessibility which the
/// MAS sandbox forbids, so the wizard compiles to nothing in MAS
/// builds.
public struct ComputerUseSetupWizard: View {
    public enum Step: Int, CaseIterable {
        case overview
        case permissions
        case sampleAction
        case complete
    }

    @StateObject private var model: ComputerUseSetupWizardModel
    let onComplete: () -> Void
    let onCancel: () -> Void

    public init(
        model: ComputerUseSetupWizardModel,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Group {
                switch model.currentStep {
                case .overview:      overviewStep
                case .permissions:   permissionsStep
                case .sampleAction:  sampleActionStep
                case .complete:      completeStep
                }
            }
            Spacer()
            footer
        }
        .padding(28)
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COMPUTER USE — SETUP")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.system(size: 22, weight: .semibold))
        }
    }

    private var headerTitle: String {
        switch model.currentStep {
        case .overview: return "What Computer Use does"
        case .permissions: return "Grant permissions"
        case .sampleAction: return "Try a benign sample action"
        case .complete: return "Setup complete"
        }
    }

    private var overviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(icon: "eye", title: "Watch on your phone",
                body: "Your paired iPhone or iPad mirrors what the agent is doing in real time.")
            row(icon: "hand.raised", title: "Approve every action by default",
                body: "Every browser click or Mac action passes through an approval sheet you control.")
            row(icon: "lock.shield", title: "Tamper-evident audit chain",
                body: "Every action is recorded with a content-addressed hash chain you can export and verify.")
            row(icon: "exclamationmark.octagon.fill", title: "Three independent kill switches",
                body: "⌃⌥⌘. global hotkey, three-finger phone gesture, lock screen — each tears down within 200 ms.")
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenBurnBar needs the macOS Accessibility permission so the agent can operate apps on your Mac during sessions you approve.")
                .font(.system(size: 13))
            HStack(spacing: 12) {
                Image(systemName: model.accessibilityGranted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.accessibilityGranted ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS Accessibility")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.accessibilityGranted
                         ? "Granted — OpenBurnBar can synthesize CGEvents."
                         : "Click Open System Settings → Privacy & Security → Accessibility → enable OpenBurnBar.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.accessibilityGranted ? "Re-check" : "Open System Settings") {
                    model.requestAccessibility()
                }
                .buttonStyle(.bordered)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: model.playwrightReady ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.playwrightReady ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playwright (Phase 9 — browser mode)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.playwrightReady
                         ? "Pinned at playwright@1.49.x. Bridge script ready."
                         : "Run scripts/install-playwright.sh to install the pinned Playwright build + Chromium.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.playwrightReady ? "Re-check" : "Install") {
                    model.installPlaywright()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sampleActionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenBurnBar will open Calculator and compute 2+2. Watch the approval sheet appear on this Mac and (if paired) on your phone — approve each click, and confirm the result is 4.")
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 6) {
                progressRow(label: "Open Calculator", status: model.sampleStatus.openCalculator)
                progressRow(label: "Click 2", status: model.sampleStatus.click2)
                progressRow(label: "Click +", status: model.sampleStatus.clickPlus)
                progressRow(label: "Click 2", status: model.sampleStatus.click2Again)
                progressRow(label: "Click =", status: model.sampleStatus.clickEquals)
                progressRow(label: "Result 4", status: model.sampleStatus.verifiedResult)
            }
            Button(model.sampleIsRunning ? "Running…" : "Run sample action") {
                model.runSampleAction()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.sampleIsRunning)
        }
    }

    private var completeStep: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.green)
            Text("Computer Use is ready.")
                .font(.system(size: 18, weight: .semibold))
            Text("Open Settings → Computer Use any time to manage trust mode, scope rules, and audit history.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .buttonStyle(.borderless)
            Spacer()
            if model.currentStep != .overview {
                Button("Back") { model.goBack() }
                    .buttonStyle(.bordered)
            }
            Button(model.currentStep == .complete ? "Done" : "Continue") {
                if model.currentStep == .complete { onComplete() }
                else { model.goForward() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canAdvance)
        }
    }

    @ViewBuilder
    private func row(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func progressRow(label: String, status: ComputerUseSetupWizardModel.StepStatus) -> some View {
        HStack {
            Image(systemName: glyph(for: status))
                .foregroundStyle(color(for: status))
            Text(label).font(.system(size: 12, design: .monospaced))
            Spacer()
            Text(status.rawValue)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func glyph(for status: ComputerUseSetupWizardModel.StepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "arrow.clockwise.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for status: ComputerUseSetupWizardModel.StepStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .yellow
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

@MainActor
public final class ComputerUseSetupWizardModel: ObservableObject {
    public enum StepStatus: String, Sendable, Equatable, CaseIterable {
        case pending, running, succeeded, failed
    }

    public struct SampleActionStatus: Sendable, Equatable {
        public var openCalculator: StepStatus = .pending
        public var click2: StepStatus = .pending
        public var clickPlus: StepStatus = .pending
        public var click2Again: StepStatus = .pending
        public var clickEquals: StepStatus = .pending
        public var verifiedResult: StepStatus = .pending

        public init() {}
    }

    @Published public var currentStep: ComputerUseSetupWizard.Step = .overview
    @Published public var accessibilityGranted: Bool = false
    @Published public var playwrightReady: Bool = false
    @Published public var sampleStatus: SampleActionStatus = SampleActionStatus()
    @Published public var sampleIsRunning: Bool = false

    public var requestAccessibility: () -> Void = {}
    public var installPlaywright: () -> Void = {}
    public var runSampleAction: () -> Void = {}

    public init() {}

    public var canAdvance: Bool {
        switch currentStep {
        case .overview: return true
        case .permissions: return accessibilityGranted
        case .sampleAction: return sampleStatus.verifiedResult == .succeeded
        case .complete: return true
        }
    }

    public func goForward() {
        guard let next = ComputerUseSetupWizard.Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    public func goBack() {
        guard let prev = ComputerUseSetupWizard.Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }
}
#endif
