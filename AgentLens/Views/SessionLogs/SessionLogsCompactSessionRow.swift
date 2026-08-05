import SwiftUI
import OpenBurnBarCore

// MARK: - Compact Session Row

struct CompactSessionRow: View {
    let record: OpenBurnBarCore.ConversationRecord
    let isSelected: Bool
    var showDeviceIndicator: Bool = false
    var modelName: String?
    var deviceIcon: String?
    let action: () -> Void
    let onResume: (AgentProvider) -> Void

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.primary(for: record.provider)
    }

    /// Short display model name, e.g. "claude-opus-4" → "Opus 4"
    private var shortModelLabel: String? {
        guard let model = modelName, !model.isEmpty else { return nil }
        return model
    }

    private var timeLabel: String {
        guard let date = record.endTime ?? record.startTime else {
            return record.indexedAt.relativeLabel
        }
        return date.relativeLabel
    }

    /// `~/Documents/Developer/imaginethat-llc` → `imaginethat-llc`. The full
    /// path stays available on hover so nothing is lost.
    private var projectLeafName: String {
        let trimmed = record.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return record.projectName }
        let leaf = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return leaf.isEmpty ? trimmed : leaf
    }

    private var displayTitle: String {
        if let summaryTitle = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryTitle.isEmpty {
            return summaryTitle
        }
        return record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? accentColor.opacity(0.18) : DesignSystem.Colors.surfaceElevated.opacity(0.6))
                            .frame(width: 28, height: 28)

                        if record.sourceType == .cliAssistant {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isSelected ? accentColor : DesignSystem.Colors.textSecondary)
                        } else {
                            ProviderLogoView(provider: record.provider, size: 16, useFallbackColor: false)
                        }
                    }

                    // Model vendor badge — small overlay in bottom-right
                    if let model = modelName, !model.isEmpty {
                        ModelProviderLogoView(modelKey: model, size: 13)
                            .background(
                                Circle()
                                    .fill(DesignSystem.Colors.surface)
                                    .frame(width: 15, height: 15)
                            )
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Text(displayTitle)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        if let label = shortModelLabel {
                            Text(label)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(LLMModelBrand.infer(fromModelKey: label).emblemColor.opacity(0.7))
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if showDeviceIndicator, record.isRemote, let deviceName = record.sourceDeviceName {
                            Image(systemName: deviceIcon ?? "desktopcomputer")
                                .font(.system(size: 8))
                            Text(deviceName)
                                .lineLimit(1)
                            Text("·")
                        }
                        Text(projectLeafName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                        Text("\(record.messageCount) msgs")
                            .monospacedDigit()
                            .layoutPriority(1)
                    }
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)

                Text(timeLabel)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs + 1)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isSelected ? accentColor : Color.clear)
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
            .contentShape(Rectangle())
            .help(record.projectName)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu {
                ForEach(AgentProvider.allCases) { provider in
                    Button {
                        onResume(provider)
                    } label: {
                        Label(provider.rawValue, systemImage: provider == record.provider ? "arrow.uturn.forward.circle.fill" : provider.iconName)
                    }
                }
            } label: {
                Label("Resume in...", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}
