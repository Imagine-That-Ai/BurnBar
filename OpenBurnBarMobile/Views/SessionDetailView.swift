import SwiftUI
import Charts
import OpenBurnBarCore

@Observable
@MainActor
final class StreamDetailStore {
    private let firestore: FirestoreRepository

    private(set) var manifest: StreamSessionLogManifest?
    private(set) var transcriptPreview: String?
    private(set) var isLoading = false
    private(set) var isLoadingTranscript = false
    private(set) var isTranscriptExpanded = false
    private(set) var errorMessage: String?

    init(firestore: FirestoreRepository = FirestoreRepository.shared) {
        self.firestore = firestore
    }

    func load(for usage: TokenUsage) async {
        isLoading = true
        errorMessage = nil
        isTranscriptExpanded = false
        transcriptPreview = nil
        defer { isLoading = false }

        do {
            guard let manifest = try await firestore.fetchSessionLogManifest(for: usage) else {
                self.manifest = nil
                return
            }
            self.manifest = manifest
            transcriptPreview = try await firestore.fetchSessionLogBody(documentID: manifest.documentID, maxCharacters: 4_000)
        } catch {
            self.manifest = nil
            errorMessage = "Stream transcript is not available from Firebase yet."
        }
    }

    func toggleFullTranscript() async {
        guard let manifest else { return }
        if isTranscriptExpanded {
            isTranscriptExpanded = false
            if let transcriptPreview {
                self.transcriptPreview = String(transcriptPreview.prefix(4_000))
            }
            return
        }
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }
        do {
            transcriptPreview = try await firestore.fetchSessionLogBody(documentID: manifest.documentID)
            isTranscriptExpanded = true
        } catch {
            errorMessage = "Unable to load the full stream body."
        }
    }
}

struct SessionDetailView: View {
    let usage: TokenUsage
    @State private var detailStore = StreamDetailStore()

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    private var themeColor: Color {
        providerEnum.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.Colors.textSecondary
    }

    private var chartPalette: [Color] {
        providerEnum.map { MobileTheme.Colors.chartPalette(for: $0) } ?? [MobileTheme.Colors.textSecondary]
    }

    /// Distinct, semantic colors for each token kind so the breakdown reads
    /// at a glance. The previous `chartPalette` returned shades of one
    /// provider color, which made input/output/cache visually identical.
    private enum TokenKind {
        case input, output, cacheCreation, cacheRead, reasoning

        var tint: Color {
            switch self {
            case .input:         return MobileTheme.whimsy            // cool blue
            case .output:        return MobileTheme.ember             // warm coral
            case .cacheCreation: return MobileTheme.amber             // gold
            case .cacheRead:     return MobileTheme.Colors.success    // green (efficiency)
            case .reasoning:     return Color(hex: "B580E8")          // violet
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                heroHeader
                tokenBreakdown
                streamCloudDetailSection
                provenanceSection
                if usage.sourceDeviceName != nil || usage.sourceDeviceId != nil {
                    deviceSection
                }
            }
            .padding(.top, MobileTheme.Spacing.lg)
            // Reserve room for the floating Aurora tab tray + home indicator
            // so the last card doesn't slide underneath it (and so the user
            // can still scroll past the end without bumping into the pill).
            .padding(.bottom, 120)
        }
        .scrollIndicators(.visible)
        .scrollDismissesKeyboard(.interactively)
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: usage.id) {
            await detailStore.load(for: usage)
        }
    }

    private var emberBackground: some View {
        EmberSurfaceBackground()
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .top) {
            UnifiedGlassCard {
                VStack(spacing: MobileTheme.Spacing.md) {
                    if let providerEnum {
                        ProviderAvatar(provider: providerEnum, mode: .aurora, size: 64)
                    }

                    Text(usage.model)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)

                    Text(providerEnum?.displayName ?? usage.provider.rawValue)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)

                    // Metric row
                    HStack(spacing: MobileTheme.Spacing.md) {
                        MetricPill(title: "Cost", value: usage.cost.formatAsCost())
                        MetricPill(title: "Tokens", value: usage.totalTokens.formatAsTokens())
                        MetricPill(title: "Duration", value: usage.formattedDuration)
                        if usage.cacheReadTokens > 0 || usage.cacheCreationTokens > 0 {
                            MetricPill(
                                title: "Cache",
                                value: String(format: "%.0f%%", cacheHitRatio * 100)
                            )
                        }
                    }
                    .padding(.top, MobileTheme.Spacing.sm)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var cacheHitRatio: Double {
        let cacheTotal = Double(usage.cacheReadTokens + usage.cacheCreationTokens)
        let total = Double(usage.totalTokens)
        guard total > 0 else { return 0 }
        return min(1, cacheTotal / total)
    }

    // MARK: - Cloud Detail

    private var streamCloudDetailSection: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack {
                    Text("Stream Detail")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                    if detailStore.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if detailStore.manifest != nil {
                        Image(systemName: "checkmark.icloud.fill")
                            .foregroundStyle(MobileTheme.success)
                    }
                }

                if let manifest = detailStore.manifest {
                    if !manifest.inferredTaskTitle.isEmpty {
                        Text(manifest.inferredTaskTitle)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                    HStack(spacing: 8) {
                        MetricPill(title: "Messages", value: "\(manifest.messageCount)")
                        MetricPill(title: "Chunks", value: "\(manifest.chunkCount)")
                        MetricPill(title: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(manifest.byteCount), countStyle: .file))
                    }
                    if let preview = detailStore.transcriptPreview, !preview.isEmpty {
                        Text(preview)
                            .font(MobileTheme.Typography.monoTiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(detailStore.isTranscriptExpanded ? nil : 8)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.55))
                            )
                    }
                    Button(detailStore.isTranscriptExpanded ? "Collapse stream" : "Load full stream") {
                        Task { await detailStore.toggleFullTranscript() }
                    }
                    .buttonStyle(.aurora(.secondary, fullWidth: true))
                    .disabled(detailStore.isLoadingTranscript)
                } else if let error = detailStore.errorMessage {
                    Text(error)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                } else {
                    Text("Full stream details appear here when transcript backup is enabled on your Mac.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Token Breakdown

    private var tokenBreakdown: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Tokens")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                // Animated horizontal token-mix bar — each segment uses
                // the same semantic tint as its row below so the visual
                // mapping is unmistakable.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        tokenMixSegment(value: usage.inputTokens, total: usage.totalTokens, color: TokenKind.input.tint, width: geo.size.width)
                        tokenMixSegment(value: usage.outputTokens, total: usage.totalTokens, color: TokenKind.output.tint, width: geo.size.width)
                        if usage.cacheReadTokens > 0 {
                            tokenMixSegment(value: usage.cacheReadTokens, total: usage.totalTokens, color: TokenKind.cacheRead.tint, width: geo.size.width)
                        }
                        if usage.cacheCreationTokens > 0 {
                            tokenMixSegment(value: usage.cacheCreationTokens, total: usage.totalTokens, color: TokenKind.cacheCreation.tint, width: geo.size.width)
                        }
                        if usage.reasoningTokens > 0 {
                            tokenMixSegment(value: usage.reasoningTokens, total: usage.totalTokens, color: TokenKind.reasoning.tint, width: geo.size.width)
                        }
                    }
                    .frame(height: 10)
                    .clipShape(Capsule())
                }
                .frame(height: 10)

                VStack(spacing: MobileTheme.Spacing.sm) {
                    TokenPill(label: "Input", value: usage.inputTokens, color: TokenKind.input.tint)
                    TokenPill(label: "Output", value: usage.outputTokens, color: TokenKind.output.tint)
                    if usage.cacheCreationTokens > 0 {
                        TokenPill(label: "Cache Creation", value: usage.cacheCreationTokens, color: TokenKind.cacheCreation.tint)
                    }
                    if usage.cacheReadTokens > 0 {
                        TokenPill(label: "Cache Read", value: usage.cacheReadTokens, color: TokenKind.cacheRead.tint)
                    }
                    if usage.reasoningTokens > 0 {
                        TokenPill(label: "Reasoning", value: usage.reasoningTokens, color: TokenKind.reasoning.tint)
                    }
                    Divider()
                        .padding(.vertical, 2)
                    TokenPill(label: "Total", value: usage.totalTokens, isTotal: true)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private func tokenMixSegment(value: Int, total: Int, color: Color, width: CGFloat) -> some View {
        let fraction = total > 0 ? CGFloat(value) / CGFloat(total) : 0
        return RoundedRectangle(cornerRadius: 0, style: .continuous)
            .fill(color)
            .frame(width: width * fraction)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Provenance")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                ProvenanceChip(label: "Method", value: usage.provenanceMethod.rawValue)
                ProvenanceChip(label: "Confidence", value: usage.provenanceConfidence.rawValue)
                ProvenanceChip(label: "Source", value: usage.usageSource.rawValue)
                if !usage.estimatorVersion.isEmpty {
                    ProvenanceChip(label: "Estimator", value: usage.estimatorVersion)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Device

    private var deviceSection: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Device")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                if let name = usage.sourceDeviceName {
                    ProvenanceChip(label: "Name", value: name)
                }
                if let id = usage.sourceDeviceId {
                    ProvenanceChip(label: "ID", value: id)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

// MARK: - Token Pill

private struct TokenPill: View {
    let label: String
    let value: Int
    var isTotal = false
    var color: Color? = nil

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            if let color {
                // Saturated swatch + faint halo gives each kind a clear,
                // distinct identity even when the provider's palette is
                // mostly one hue.
                ZStack {
                    Circle()
                        .fill(color.opacity(0.22))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                }
                .accessibilityHidden(true)
            }
            Text(label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(isTotal ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                .fontWeight(isTotal ? .semibold : .regular)
            Spacer(minLength: 8)
            Text(value.formatAsTokens())
                .font(isTotal ? MobileTheme.Typography.headline : MobileTheme.Typography.body)
                .fontWeight(isTotal ? .bold : .medium)
                .foregroundStyle(isTotal ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textPrimary.opacity(0.85))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value.formatAsTokens())")
    }
}

// MARK: - Metric Pill

private struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(title)
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
        )
    }
}

// MARK: - Provenance Chip

private struct ProvenanceChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated)
                )
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(usage: TokenUsage(
            provider: .claudeCode,
            sessionId: "sess-123",
            projectName: "Demo",
            model: "claude-3-5-sonnet-20241022",
            inputTokens: 120_000,
            outputTokens: 45_000,
            cacheCreationTokens: 5_000,
            cacheReadTokens: 8_000,
            reasoningTokens: 2_000,
            costUSD: 1.23,
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            usageSource: .providerLog,
            sourceDeviceId: "device-abc",
            sourceDeviceName: "MacBook Pro",
            isRemote: false,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        ))
    }
}
