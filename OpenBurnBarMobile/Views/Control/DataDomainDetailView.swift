import SwiftUI
import OpenBurnBarCore

// MARK: - Per-domain control
//
// Drill-in for one data domain: the tier promise, exactly what the server can
// see vs what stays on-device, live footprint, and the scoped actions the
// registry advertises (export / delete / sync / revoke). Delete routes through
// `deleteDomainData` (scoped to that domain's firestore + storage paths).

struct DataDomainDetailView: View {
    let domain: DataDomain
    @Bindable var store: DataVaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false

    private var usage: DataDomainUsageRow? { store.usage(for: domain.id) }
    private var isDeleting: Bool { store.deletingDomainID == domain.id }

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    header
                    promiseCard
                    visibilityCard
                    if !domain.deviceOnly.isEmpty { deviceOnlyCard }
                    footprintCard
                    actionsCard
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
            }
        }
        .navigationTitle(domain.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Delete all \(domain.title)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(domain.title)", role: .destructive) {
                Task {
                    HapticBus.destructive()
                    if await store.deleteDomain(domain.id) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every \(domain.title.lowercased()) record from the cloud. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: domain.icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(domain.encryptionTier.tierColor)
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(domain.encryptionTier.tierColor.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: domain.encryptionTier.lockSymbol)
                        .font(.system(size: 11, weight: .bold))
                    Text(domain.encryptionTier.shortLabel)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(0.6)
                }
                .foregroundStyle(domain.encryptionTier.tierColor)
                Text(retentionLabel)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promiseCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(domain.summary)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(domain.encryptionTier.promise)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(domain.encryptionTier.tierColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var visibilityCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                cardTitle("What the server can see", tint: EncryptionTier.serverReadable.tierColor)
                if domain.serverSees.isEmpty {
                    Text("Nothing — this domain is sealed end-to-end.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    facetGrid(domain.serverSees, tint: EncryptionTier.serverReadable.tierColor)
                }
            }
        }
    }

    private var deviceOnlyCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                cardTitle("Stays on your devices only", tint: EncryptionTier.endToEnd.tierColor)
                facetGrid(domain.deviceOnly, tint: EncryptionTier.endToEnd.tierColor)
            }
        }
    }

    private var footprintCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud footprint")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    Text(footprintLabel)
                        .font(MobileTheme.Typography.monoLarge)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
        }
    }

    private var actionsCard: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            if domain.actions.contains("sync"), domain.id == "pensieve" {
                Button {
                    Task { await store.syncKnowledgeNow() }
                } label: {
                    Label(store.isSyncingKnowledge ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.secondary, fullWidth: true))
                .disabled(store.isSyncingKnowledge)
            }

            if domain.actions.contains("delete") {
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        if isDeleting { ProgressView().controlSize(.small) }
                        Text(isDeleting ? "Deleting…" : "Delete all \(domain.title)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.destructive, fullWidth: true))
                .disabled(isDeleting)
            }

            if !mutableActions {
                Text(readOnlyHint)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Helpers

    private func cardTitle(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
    }

    private func facetGrid(_ facets: [String], tint: Color) -> some View {
        FlexibleChipFlow(items: facets) { facet in
            Text(facet)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous).fill(tint.opacity(0.12))
                )
        }
    }

    private var retentionLabel: String {
        let raw = domain.retention.replacingOccurrences(of: "_", with: " ")
        return "Retention: \(raw)"
    }

    private var footprintLabel: String {
        guard let usage else { return "—" }
        var label = "\(usage.count)"
        if usage.bytes > 0 { label += " · \(DataVaultFormat.bytes(usage.bytes))" }
        return label
    }

    private var mutableActions: Bool {
        domain.actions.contains("delete") || (domain.actions.contains("sync") && domain.id == "pensieve")
    }

    private var readOnlyHint: String {
        if domain.actions.contains("revoke") {
            return "Manage connections from their own screen — revoking happens there."
        }
        if domain.id == "entitlements_billing" {
            return "Billing history is kept for your records and can't be deleted here."
        }
        if domain.id == "audit_timeline" {
            return "The audit log is append-only and tamper-evident — it can't be edited."
        }
        return "This domain is view-only here."
    }
}

// MARK: - Flexible chip flow (wraps chips to new lines)

struct FlexibleChipFlow<Item: Hashable, ChipContent: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> ChipContent

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in chip(item) }
        }
    }
}

/// Minimal flow layout so registry facets wrap cleanly without a fixed grid.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
