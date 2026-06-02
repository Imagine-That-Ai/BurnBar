import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Domain inspector
//
// The right-hand HSplitView pane. For the selected domain it shows:
//   • header (icon, title, tier badge, retention)
//   • the yours↔server flip (the governance centerpiece)
//   • a Swift Charts usage meter (count + bytes, with Pensieve hard caps when
//     the selected domain is Pensieve)
//   • the firestore/storage paths and per-domain actions (export / delete /
//     recover / verify) wired to the view model callables.

struct DomainInspector: View {
    @Bindable var viewModel: DataControlCenterViewModel
    let row: DataControlCenterViewModel.DomainRow
    var onDelete: () -> Void
    var onRecover: () -> Void
    var onExportDomain: () -> Void

    private var domain: DataDomain { row.domain }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                YoursVsServerFlip(domain: domain)
                usageCard
                if domain.id == "pensieve" { pensieveLimitsCard }
                if domain.id == "audit_timeline" { auditCard }
                pathsCard
                actionsRow
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(domain.encryptionTier.tint.gradient)
                Image(systemName: domain.icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(domain.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(domain.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TierBadge(tier: domain.encryptionTier)
                    Text(retentionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DesignSystem.Colors.surface.opacity(0.6)))
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var retentionLabel: String {
        switch domain.retention {
        case "rolling": return "Rolling window"
        case "until_deleted": return "Kept until you delete it"
        case "until_revoked": return "Kept until revoked"
        case "until_disconnected": return "Kept until disconnected"
        case "append_only": return "Append-only"
        case "permanent": return "Permanent record"
        default: return domain.retention.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Usage chart (Swift Charts)

    private var usageCard: some View {
        InspectorCard(title: "FOOTPRINT", icon: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    metric(value: "\(row.count)", label: countLabel)
                    if domain.byteSource != nil {
                        metric(value: byteString(row.bytes), label: "Stored")
                    }
                }

                Chart {
                    BarMark(
                        x: .value("Records", row.count),
                        y: .value("Domain", domain.title)
                    )
                    .foregroundStyle(domain.encryptionTier.tint.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) {
                        AxisGridLine().foregroundStyle(DesignSystem.Colors.border.opacity(0.3))
                        AxisValueLabel().font(.system(size: 9, design: .monospaced))
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 44)
                .accessibilityLabel("\(domain.title) footprint")
                .accessibilityValue("\(row.count) records")
            }
        }
    }

    private var countLabel: String {
        domain.countSource?.replacingOccurrences(of: "_", with: " ") ?? "Records"
    }

    // MARK: Pensieve hard caps (Swift Charts gauge meters)

    private var pensieveLimitsCard: some View {
        InspectorCard(title: "PENSIEVE LIMITS", icon: "gauge.with.dots.needle.50percent") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your \(viewModel.tier.rawValue.capitalized) plan caps Pensieve knowledge at these ceilings.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                limitMeter(
                    title: "Chunks",
                    used: row.count,
                    limit: viewModel.pensieveLimits.chunks
                )
                limitMeter(
                    title: "Storage",
                    usedBytes: row.bytes,
                    limitBytes: viewModel.pensieveLimits.bytes
                )
            }
        }
    }

    @ViewBuilder
    private func limitMeter(title: String, used: Int, limit: Int) -> some View {
        let fraction = limit > 0 ? min(1, Double(used) / Double(limit)) : 0
        meterBar(title: title, value: "\(used) / \(limit)", fraction: fraction)
    }

    @ViewBuilder
    private func limitMeter(title: String, usedBytes: Int64, limitBytes: Int64) -> some View {
        let fraction = limitBytes > 0 ? min(1, Double(usedBytes) / Double(limitBytes)) : 0
        meterBar(title: title, value: "\(byteString(usedBytes)) / \(byteString(limitBytes))", fraction: fraction)
    }

    private func meterBar(title: String, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(fraction > 0.9 ? DesignSystem.Colors.warning : PensieveTheme.endToEnd)
        }
    }

    // MARK: Audit timeline card (getAuditLog / verifyAuditLog)

    private var auditCard: some View {
        InspectorCard(title: "TAMPER-EVIDENT LOG", icon: "checkmark.shield.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        Task { await viewModel.verifyAuditLog() }
                    } label: {
                        Label("Verify chain", systemImage: "checkmark.seal")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isMutating)

                    if let verification = viewModel.auditVerification {
                        if verification.valid {
                            Label("Intact", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.success)
                        } else {
                            Label("Broken at \(verification.brokenAt ?? -1)", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PensieveTheme.waxCrimson)
                        }
                    }
                    Spacer()
                }

                if viewModel.auditEvents.isEmpty {
                    Text(viewModel.isLoadingAudit ? "Loading audit events…" : "No audit events yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    ForEach(viewModel.auditEvents.prefix(12)) { event in
                        auditRow(event)
                    }
                    if viewModel.auditNextCursor != nil {
                        Button("Load more") {
                            Task { await viewModel.refreshAuditLog(reset: false) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .task { if viewModel.auditEvents.isEmpty { await viewModel.refreshAuditLog() } }
    }

    private func auditRow(_ event: DataControlCenterViewModel.AuditEvent) -> some View {
        HStack(spacing: 8) {
            Text("#\(event.seq)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(event.actor) · \(event.action)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Text(event.domain)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            if let ts = event.ts {
                Text(ts.relativeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Paths card

    private var pathsCard: some View {
        InspectorCard(title: "WHERE IT LIVES", icon: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if domain.firestorePaths.isEmpty == false {
                    facetGroup(title: "Collections", items: domain.firestorePaths, icon: "tablecells", tint: domain.encryptionTier.tint)
                }
                if domain.storagePaths.isEmpty == false {
                    facetGroup(title: "Storage", items: domain.storagePaths, icon: "shippingbox.fill", tint: PensieveTheme.mercuryDeep)
                }
            }
        }
    }

    private func facetGroup(title: String, items: [String], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            FlowChips(items: items, icon: icon, tint: tint)
        }
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 10) {
            if domain.actions.contains("export") {
                Button {
                    onExportDomain()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isExporting)
            }
            if domain.actions.contains("recover") {
                Button {
                    onRecover()
                } label: {
                    Label("Recovery", systemImage: "key.horizontal.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            if domain.actions.contains("delete") {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(PensieveTheme.waxCrimson)
                .disabled(viewModel.isMutating)
            }
        }
    }

    // MARK: Helpers

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(label.capitalized)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
}

// MARK: - Tier badge

struct TierBadge: View {
    let tier: EncryptionTier
    var body: some View {
        Label(tier.displayLabel, systemImage: tier.iconName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tier.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tier.tint.opacity(0.14)))
            .overlay(Capsule().stroke(tier.tint.opacity(0.4), lineWidth: 0.5))
    }
}

// MARK: - Inspector card chrome

struct InspectorCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(PensieveTheme.brassCore)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(reduceTransparency ? AnyShapeStyle(DesignSystem.Colors.surface) : AnyShapeStyle(.ultraThinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.6)
        )
    }
}
