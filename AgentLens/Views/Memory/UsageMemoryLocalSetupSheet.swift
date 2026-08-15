import SwiftUI

// MARK: - Usage-memory local model setup wizard (U3)

/// The U3 setup wizard: detects a running Ollama, pulls the local curation
/// model(s) with streamed progress, verifies, done. Presented on top of
/// whichever surface posted `.usageMemoryLocalModelSetupRequested` (the U2
/// consent sheet's placement step, or Settings → Privacy's usage section) via
/// `usageMemoryLocalSetupPresenter(settingsManager:)`.
///
/// The wizard never downloads or installs Ollama itself — the missing-Ollama
/// step only links out to ollama.com/download and re-polls. Model pulls go
/// through Ollama's own `/api/pull`. State machine + transport live in
/// `UsageMemoryLocalSetupModel`.
struct UsageMemoryLocalSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: UsageMemoryLocalSetupModel
    /// Session-only choice; never persisted (placement/persistence is U2's
    /// domain, and `usageMemoryLocalVLModel` itself stays untouched).
    @State private var includeVision = false

    init(settingsManager: SettingsManager) {
        self._model = State(initialValue: UsageMemoryLocalSetupModel(settingsManager: settingsManager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            switch model.state {
            case .checking:
                checkingContent
            case .ollamaMissing:
                ollamaMissingContent
            case .readyToDownload(let installed):
                readyContent(installed: installed)
            case .downloading(let name, let progress, let completedBytes, let totalBytes):
                downloadingContent(
                    modelName: name,
                    progress: progress,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                )
            case .verifying:
                verifyingContent
            case .done:
                doneContent
            case .failed(let message, let retryable):
                failedContent(message: message, retryable: retryable)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 480)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .liquidGlassSurface(
            in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous),
            fallback: .ultraThinMaterial
        )
        .task {
            await model.detect()
        }
        .onDisappear {
            model.endAutoRecheck()
        }
    }

    // MARK: Header (system requirements — same numbers as the consent copy)

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.35),
                                DesignSystem.Colors.amber.opacity(0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Set up the local model")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Runs curation entirely on this Mac through Ollama. "
                    + UsageMemoryPlacementCopy.localSystemRequirements)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Checking

    private var checkingContent: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Checking for Ollama…")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: Ollama missing (link out only — never auto-install)

    private var ollamaMissingContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label {
                Text("Ollama isn't running on this Mac. Install it from ollama.com, "
                    + "launch it, and this wizard continues automatically.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(DesignSystem.Colors.warning)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Link(destination: URL(string: "https://ollama.com/download")!) {
                    Label("Open ollama.com/download", systemImage: "safari")
                        .font(DesignSystem.Typography.caption)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button("Check again") {
                    Task { await model.detect() }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
            }
        }
        .onAppear { model.beginAutoRecheck() }
        .onDisappear { model.endAutoRecheck() }
    }

    // MARK: Ready to download

    private func readyContent(installed: [String]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            modelRow(
                name: model.requiredTextModel,
                detail: "Curation text model",
                isInstalled: UsageMemoryLocalSetupModel.isInstalled(model.requiredTextModel, in: installed)
            )

            if let visionModel = model.visionModel {
                SettingsToggle(
                    title: "Also understand screenshots locally (~9 GB memory)",
                    subtitle: UsageMemoryLocalSetupModel.isInstalled(visionModel, in: installed)
                        ? "\(visionModel) — already installed."
                        : "Downloads \(visionModel) so image candidates stay on this Mac too.",
                    isOn: $includeVision
                )
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button(downloadButtonTitle(installed: installed)) {
                    Task { await model.startSetup(includeVision: includeVision) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func downloadButtonTitle(installed: [String]) -> String {
        let textInstalled = UsageMemoryLocalSetupModel.isInstalled(model.requiredTextModel, in: installed)
        let visionPending = includeVision
            && model.visionModel.map { !UsageMemoryLocalSetupModel.isInstalled($0, in: installed) } == true
        return (textInstalled && !visionPending) ? "Verify" : "Download"
    }

    private func modelRow(name: String, detail: String, isInstalled: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(isInstalled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(isInstalled ? "\(detail) — already installed." : detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Downloading

    private func downloadingContent(
        modelName: String,
        progress: Double,
        completedBytes: Int64,
        totalBytes: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ProgressView(value: progress)
                .tint(DesignSystem.Colors.ember)

            HStack {
                Text("Downloading \(modelName)…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                if totalBytes > 0 {
                    Text("\(Self.megabytes(completedBytes)) of \(Self.megabytes(totalBytes))")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: Verifying

    private var verifyingContent: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Verifying the installed models…")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: Done

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label {
                Text("Local model ready. Usage-memory curation now runs entirely on this Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Failed

    private func failedContent(message: String, retryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label {
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                if retryable {
                    Button("Retry") {
                        Task { await model.startSetup(includeVision: includeVision) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.ember)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Shared presenter

/// Observes `.usageMemoryLocalModelSetupRequested` and presents the wizard as
/// a sheet on whatever it decorates. Attached to the consent-sheet content in
/// its integrators (so the wizard stacks on top of the consent sheet) and to
/// Settings → Privacy's usage section (for its direct "Set up local model…"
/// affordance).
///
/// `isActive` lets a host stand down while a sibling surface it also hosts is
/// the one that should present (e.g. Settings' usage section defers to its own
/// consent sheet). The notification is intentionally unrouted, so in the
/// contrived case of two independent posting surfaces alive in different
/// windows at once, each active observer presents in its own window.
private struct UsageMemoryLocalSetupPresenter: ViewModifier {
    let settingsManager: SettingsManager
    var isActive: Bool = true
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .usageMemoryLocalModelSetupRequested)
            ) { _ in
                if isActive {
                    isPresented = true
                }
            }
            .sheet(isPresented: $isPresented) {
                UsageMemoryLocalSetupSheet(settingsManager: settingsManager)
                    .presentationBackground(Material.ultraThinMaterial)
            }
    }
}

extension View {
    /// Presents the U3 local-model setup wizard whenever
    /// `.usageMemoryLocalModelSetupRequested` is posted (while `isActive`).
    func usageMemoryLocalSetupPresenter(
        settingsManager: SettingsManager,
        isActive: Bool = true
    ) -> some View {
        modifier(UsageMemoryLocalSetupPresenter(
            settingsManager: settingsManager,
            isActive: isActive
        ))
    }
}
