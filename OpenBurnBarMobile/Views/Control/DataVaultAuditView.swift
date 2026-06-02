import SwiftUI
import OpenBurnBarCore

// MARK: - Access audit log
//
// The tamper-evident hash chain: every actor/action/domain/timestamp with its
// prevHash → hash links, plus a one-tap integrity verification. Binds to
// getAuditLog (paged) + verifyAuditLog.

struct DataVaultAuditView: View {
    @Bindable var store: DataVaultStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                LazyVStack(spacing: MobileTheme.Spacing.sm) {
                    verifyCard

                    if store.auditEvents.isEmpty {
                        AuroraStatePane(
                            kind: .empty,
                            icon: "list.bullet.rectangle.portrait",
                            title: "No access events yet",
                            message: "When an agent, device, or grant touches your data, it lands here."
                        )
                        .padding(.top, MobileTheme.Spacing.xl)
                    } else {
                        ForEach(store.auditEvents) { event in
                            AuditEventRow(event: event, isBreakPoint: store.auditBrokenAt == event.seq)
                        }
                        if store.auditCursor != nil {
                            Button("Load more") {
                                Task { await store.loadAudit() }
                            }
                            .buttonStyle(.aurora(.secondary))
                            .padding(.top, MobileTheme.Spacing.sm)
                        }
                    }

                    if let error = store.error { DataVaultInlineError(message: error) }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
            }
            .refreshable { await store.loadAudit(reset: true) }
        }
        .navigationTitle("Access audit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .task {
            if store.auditEvents.isEmpty { await store.loadAudit(reset: true) }
        }
    }

    private var verifyCard: some View {
        AuroraGlassCard(variant: verifyVariant, cornerRadius: 16) {
            HStack(spacing: 12) {
                Image(systemName: verifyIcon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(verifyTint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(verifyTint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verifyTitle)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(verifySubtitle)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                Button("Verify") {
                    Task {
                        HapticBus.primaryAction()
                        await store.verifyAudit()
                    }
                }
                .buttonStyle(.aurora(.secondary))
            }
        }
    }

    private var verifyVariant: AuroraGlassVariant {
        switch store.auditVerified {
        case .some(true): return .success
        case .some(false): return .urgent
        case .none: return .standard
        }
    }

    private var verifyTint: Color {
        switch store.auditVerified {
        case .some(true): return MobileTheme.success
        case .some(false): return Color(hex: PensieveTokens.colorSealCrimson)
        case .none: return EncryptionTier.serverReadable.tierColor
        }
    }

    private var verifyIcon: String {
        switch store.auditVerified {
        case .some(true): return "checkmark.seal.fill"
        case .some(false): return "exclamationmark.triangle.fill"
        case .none: return "seal"
        }
    }

    private var verifyTitle: String {
        switch store.auditVerified {
        case .some(true): return "Chain intact"
        case .some(false): return "Chain broken"
        case .none: return "Hash-chained log"
        }
    }

    private var verifySubtitle: String {
        switch store.auditVerified {
        case .some(true): return "Every link verifies — nothing was altered or removed."
        case .some(false):
            if let at = store.auditBrokenAt { return "Integrity break detected at event #\(at)." }
            return "An integrity break was detected."
        case .none: return "Tap Verify to recompute the whole chain on the server."
        }
    }
}

private struct AuditEventRow: View {
    let event: AuditLogEvent
    let isBreakPoint: Bool

    var body: some View {
        AuroraGlassCard(variant: isBreakPoint ? .urgent : .standard, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("#\(event.seq)")
                        .font(MobileTheme.Typography.monoTiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text(event.action)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                    if let domain = event.domain, let registry = DataDomains.domain(domain) {
                        Image(systemName: registry.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(registry.encryptionTier.tierColor)
                    }
                }
                HStack(spacing: 8) {
                    Label(event.actor, systemImage: "person.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    Spacer()
                    Text(event.ts)
                        .font(MobileTheme.Typography.monoTiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Text(event.hash.prefix(18) + "…")
                    .font(MobileTheme.Typography.monoTiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }
}
