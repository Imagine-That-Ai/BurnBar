import SwiftUI
import OpenBurnBarCore

struct SessionResumeRequest: Identifiable {
    let id = UUID()
    let record: OpenBurnBarCore.ConversationRecord
    let targetHarness: AgentProvider
}

struct ResumeConversationSheet: View {
    let record: OpenBurnBarCore.ConversationRecord
    let initialTargetHarness: AgentProvider
    var daemonManager: OpenBurnBarDaemonManager

    @Environment(\.dismiss) private var dismiss
    @State private var targetHarness: AgentProvider
    @State private var response: BurnBarRunResumeResponse?
    @State private var isLoading = false
    @State private var isOpening = false
    @State private var isSpawning = false
    @State private var errorMessage: String?
    @State private var openedPath: String?

    init(
        record: OpenBurnBarCore.ConversationRecord,
        initialTargetHarness: AgentProvider,
        daemonManager: OpenBurnBarDaemonManager
    ) {
        self.record = record
        self.initialTargetHarness = initialTargetHarness
        self.daemonManager = daemonManager
        _targetHarness = State(initialValue: initialTargetHarness)
    }

    private var title: String {
        record.summaryTitle?.nonEmpty ?? record.inferredTaskTitle.nonEmpty ?? "Session"
    }

    private var previewText: String {
        guard let response else {
            return errorMessage ?? "Rendering resume briefing..."
        }
        switch response.kind {
        case "native":
            let cwd = response.workingDirectory.map { "# Run from: \($0)\n" } ?? ""
            return cwd + (response.argv ?? []).joined(separator: " ")
        case "ported":
            let note = response.note.map { "# note: \($0)\n" } ?? ""
            return note + (response.briefingMD ?? "")
        case "error":
            return "error: \(response.errorCode ?? "unknown")\n\(response.errorRecovery ?? "")"
        case "spawned":
            return "Spawned \(response.targetHarness ?? "target") pid=\(response.pid.map(String.init) ?? "unknown")"
        default:
            return "error: unknown response kind '\(response.kind)'"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            Picker("Harness", selection: $targetHarness) {
                ForEach(AgentProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: targetHarness) { _, _ in
                Task { await loadPreview() }
            }

            previewPane

            HStack(spacing: DesignSystem.Spacing.md) {
                if let openedPath {
                    Text(openedPath)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await spawnResume() }
                } label: {
                    if isSpawning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Spawn", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || isOpening || isSpawning)

                Button {
                    Task { await openResume() }
                } label: {
                    if isOpening {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .disabled(isLoading || isOpening || isSpawning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 680, minHeight: 560)
        .background(DesignSystem.Colors.surface)
        .task { await loadPreview() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: record.provider, size: 30, useFallbackColor: false)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Resume Session")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(record.provider.rawValue)
                    Text("→")
                    Text(targetHarness.rawValue)
                    if let workingDirectory = record.workingDirectory?.nonEmpty {
                        Text("·")
                        Text(workingDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()
        }
    }

    private var previewPane: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                Text(previewText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(errorMessage == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
            }
            .background(DesignSystem.Colors.background.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
            )

            if isLoading {
                ProgressView()
                    .padding(DesignSystem.Spacing.md)
            }
        }
        .frame(minHeight: 360)
    }

    private func loadPreview() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await daemonManager.runResume(
                sessionID: record.id,
                targetHarness: targetHarness.rawValue,
                mode: .print
            )
            response = result
            if let error = result.errorRecovery ?? result.errorCode {
                errorMessage = error
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func openResume() async {
        isOpening = true
        errorMessage = nil
        do {
            let result = try await daemonManager.runResume(
                sessionID: record.id,
                targetHarness: targetHarness.rawValue,
                mode: .open
            )
            response = result
            switch result.kind {
            case "native":
                openedPath = (result.argv ?? []).joined(separator: " ")
            case "ported":
                openedPath = result.briefingPath
            case "error":
                errorMessage = result.errorRecovery ?? result.errorCode.map { "The resume operation failed (\($0))." } ?? "The resume operation failed."
            default:
                errorMessage = "Unexpected response kind '\(result.kind)'."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isOpening = false
    }

    private func spawnResume() async {
        isSpawning = true
        errorMessage = nil
        do {
            let result = try await daemonManager.runResume(
                sessionID: record.id,
                targetHarness: targetHarness.rawValue,
                mode: .spawn
            )
            response = result
            switch result.kind {
            case "spawned":
                openedPath = "Spawned \(result.targetHarness ?? "target") pid=\(result.pid.map(String.init) ?? "unknown")"
            case "error":
                errorMessage = result.errorRecovery ?? result.errorCode.map { "The spawn operation failed (\($0))." } ?? "The spawn operation failed."
            default:
                errorMessage = "Expected spawned response, got '\(result.kind)'."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSpawning = false
    }
}
