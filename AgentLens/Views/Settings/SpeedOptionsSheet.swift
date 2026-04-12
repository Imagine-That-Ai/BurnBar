import SwiftUI

// MARK: - Speed Options Sheet

/// Sheet for optimizing summarization speed by switching to faster models
struct SpeedOptionsSheet: View {
    let currentModel: String
    let tps: Double
    let pendingCount: Int
    let onDiskNames: Set<String>
    let onSelectModel: (String) -> Void
    let onSelectMLX: (String) -> Void
    let onSelectCloud: (SummaryProviderID) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct LocalOption: Identifiable {
        let id: String
        let size: String
        let description: String
    }

    private let options: [LocalOption] = [
        LocalOption(id: "qwen3.5:9b",   size: "5.8 GB", description: "Best quality summaries"),
        LocalOption(id: "qwen3.5:4b",   size: "2.6 GB", description: "Good balance of speed/quality"),
        LocalOption(id: "qwen3.5:2b",   size: "1.5 GB", description: "Fast, lower quality"),
        LocalOption(id: "qwen3.5:0.8b", size: "522 MB", description: "Fastest, minimal quality"),
        LocalOption(id: "llama3.2:3b",  size: "2.0 GB", description: "Meta Llama 3.2 alternative"),
        LocalOption(id: "phi3.5:3.8b",  size: "2.2 GB", description: "Microsoft Phi-3.5 alternative"),
    ]

    private var fasterOptions: [LocalOption] {
        guard let idx = options.firstIndex(where: { $0.id == currentModel }) else {
            return options.filter { $0.id != currentModel }
        }
        return Array(options[(idx + 1)...])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "gauge.medium.badge.plus")
                            .foregroundStyle(DesignSystem.Colors.amber)
                        Text("Optimize Speed")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    Group {
                        if pendingCount > 0 {
                            Text("Current: \(currentModel) · \(String(format: "%.0f", tps)) tok/s · \(pendingCount) sessions pending")
                        } else {
                            Text("Current: \(currentModel) · \(String(format: "%.0f", tps)) tok/s")
                        }
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(DesignSystem.Spacing.lg)

            Divider().background(DesignSystem.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                    // Faster local models
                    if !fasterOptions.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Label("Faster Local Models", systemImage: "cpu")
                                .font(DesignSystem.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Text("Smaller models run significantly faster at the cost of summary quality.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(spacing: 0) {
                                ForEach(fasterOptions) { option in
                                    localOptionRow(option)
                                    if option.id != fasterOptions.last?.id {
                                        Divider().background(DesignSystem.Colors.border)
                                    }
                                }
                            }
                            .background(DesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                        }
                    }

                    // MLX option (Apple Silicon)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Apple MLX (Fastest Local)", systemImage: "memorychip.fill")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("Uses Apple GPU + Neural Engine. Requires mlx_lm.server running on port 8080.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            mlxOptionRow("mlx-community/Qwen3-4B-4bit", "~2.4 GB · Best for summarization")
                            Divider().background(DesignSystem.Colors.border)
                            mlxOptionRow("mlx-community/Qwen3-1.7B-4bit", "~1.0 GB · Ultra-fast, good quality")
                            Divider().background(DesignSystem.Colors.border)
                            mlxOptionRow("mlx-community/Llama-3.2-3B-Instruct-4bit", "~1.8 GB · Meta Llama 3.2")
                        }
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                    }

                    // Cloud providers
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Label("Switch to Cloud", systemImage: "cloud")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text("Prioritize a cloud provider. Local Ollama becomes the fallback.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            cloudOptionRow(
                                provider: .openrouter,
                                name: "OpenRouter",
                                description: "Fast inference, 200+ models, pay-per-token",
                                icon: AnyView(
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color(hex: "00A67E").opacity(0.15))
                                        Image(systemName: "arrow.triangle.branch")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color(hex: "00A67E"))
                                    }.frame(width: 34, height: 34)
                                )
                            )
                            Divider().background(DesignSystem.Colors.border)
                            cloudOptionRow(
                                provider: .minimax,
                                name: "MiniMax",
                                description: "High-speed, low-cost cloud API",
                                icon: AnyView(ProviderLogoView(provider: .minimax, size: 34, useFallbackColor: true))
                            )
                            Divider().background(DesignSystem.Colors.border)
                            cloudOptionRow(
                                provider: .zai,
                                name: "Z.ai",
                                description: "Sub-second cloud summaries",
                                icon: AnyView(ProviderLogoView(provider: .zai, size: 34, useFallbackColor: true))
                            )
                        }
                        .background(DesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider().background(DesignSystem.Colors.border)

            HStack {
                Spacer()
                Button("Keep current model") { dismiss() }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .frame(width: 480)
        .frame(minHeight: 500)
        .background(DesignSystem.Colors.background)
    }

    @ViewBuilder
    private func localOptionRow(_ option: LocalOption) -> some View {
        let isOnDisk = onDiskNames.contains(option.id)
        HStack(spacing: DesignSystem.Spacing.md) {
            ModelProviderLogoView(modelKey: option.id, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(option.id)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    if isOnDisk {
                        Text("on disk")
                            .font(DesignSystem.Typography.tiny)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DesignSystem.Colors.success.opacity(0.15))
                            .foregroundStyle(DesignSystem.Colors.success)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text(option.description)
                    Text("·")
                    Text(option.size)
                }
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            Button(isOnDisk ? "Use" : "Download & Use") {
                onSelectModel(option.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isOnDisk ? DesignSystem.Colors.blaze : nil)
        }
        .padding(DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func mlxOptionRow(_ modelId: String, _ subtitle: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ModelProviderLogoView(modelKey: modelId, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(modelId)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Button("Use") { onSelectMLX(modelId) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func cloudOptionRow(provider: SummaryProviderID, name: String, description: String, icon: AnyView) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(description)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            Button("Prioritize") {
                onSelectCloud(provider)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DesignSystem.Colors.blaze)
        }
        .padding(DesignSystem.Spacing.md)
    }
}
