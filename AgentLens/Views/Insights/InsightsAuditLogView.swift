import SwiftUI
import OpenBurnBarCore

/// Surface for the local Insights audit log — every investigation that
/// has been started, succeeded, cancelled, or failed.
///
/// Presented as a sheet from the workspace toolbar. Read-only; user can
/// only clear the log.
struct InsightsAuditLogView: View {

    let auditLog: InsightAuditLog
    @Binding var isPresented: Bool

    @State private var entries: [InsightAuditLog.Entry] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            header
            content
        }
        .padding(UnifiedDesignSystem.Spacing.xl)
        .frame(width: 680, height: 520)
        .background(UnifiedDesignSystem.Colors.background)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audit log")
                    .font(UnifiedDesignSystem.Typography.title)
                Text("Every model investigation that touched your data.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }
            Spacer()
            Button("Clear", role: .destructive) {
                Task {
                    try? await auditLog.clear()
                    await load()
                }
            }
            .disabled(entries.isEmpty)
            Button("Close") { isPresented = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                ProgressView()
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(UnifiedDesignSystem.Colors.error)
                Text(loadError).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 24))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                Text("No investigations yet.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(entries) {
                TableColumn("When") { entry in
                    Text(entry.startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Model") { entry in
                    HStack(spacing: 4) {
                        Image(systemName: entry.egressTier.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(entry.modelTag.displayName)
                            .font(.caption)
                    }
                }
                .width(min: 140, ideal: 180)
                TableColumn("Egress") { entry in
                    Text(entry.egressTier.displayLabel)
                        .font(.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Status") { entry in
                    Text(entry.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(color(for: entry.status))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Bytes") { entry in
                    Text(byteCountFormatter.string(fromByteCount: Int64(entry.digestBytes)))
                        .font(.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Cost") { entry in
                    if let usage = entry.tokenUsage, usage.estimatedCostUSD > 0 {
                        Text(InsightFormatting.format(usage.estimatedCostUSD, as: .currency))
                            .font(.caption)
                    } else {
                        Text("—").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 80)
                TableColumn("Prompt") { entry in
                    Text(entry.prompt)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private func color(for status: InsightAuditLog.Entry.Status) -> Color {
        switch status {
        case .started: return UnifiedDesignSystem.Colors.whimsy
        case .succeeded: return UnifiedDesignSystem.Colors.success
        case .cancelled: return UnifiedDesignSystem.Colors.textMuted
        case .failed: return UnifiedDesignSystem.Colors.error
        }
    }

    private var byteCountFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useBytes]
        return f
    }

    private func load() async {
        isLoading = true
        do {
            let loaded = try await auditLog.readAll(limit: 500)
            entries = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
