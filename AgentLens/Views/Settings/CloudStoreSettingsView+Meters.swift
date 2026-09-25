import SwiftUI

extension CloudStoreSettingsView {
    func meterRow(title: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(tint)
        }
    }

    func backupMetricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.08))
        )
    }

    func backupUsageMeter(_ usage: CloudBackupUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Backup usage", systemImage: "externaldrive.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 8)
                Text(usage.isWithinLimits ? "Included" : "Limit reached")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(usage.isWithinLimits ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill((usage.isWithinLimits ? DesignSystem.Colors.success : DesignSystem.Colors.warning).opacity(0.14))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                meterRow(
                    title: "Conversation backup",
                    value: "\(CloudBackupUsageSnapshot.formatBytes(usage.rawTranscriptBytes)) of \(CloudBackupUsageSnapshot.formatBytes(usage.limits.transcriptByteLimit))",
                    fraction: usage.transcriptUsageFraction,
                    tint: DesignSystem.Colors.ember
                )
                meterRow(
                    title: "Searchable index",
                    value: "\(CloudBackupUsageSnapshot.formatBytes(usage.estimatedSearchIndexBytes)) of \(CloudBackupUsageSnapshot.formatBytes(usage.limits.searchableIndexByteLimit))",
                    fraction: usage.searchIndexUsageFraction,
                    tint: DesignSystem.Colors.teal
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                backupMetricPill(title: "Conversations", value: "\(usage.conversationCount)")
                backupMetricPill(title: "Waiting", value: "\(usage.pendingConversationCount)")
                backupMetricPill(title: "Indexed parts", value: "\(usage.searchChunkCount)")
            }

            if let blockingReason = usage.blockingReason {
                Label(blockingReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.6)
        )
        .accessibilityIdentifier("macCloud.backupUsage")
    }
}
