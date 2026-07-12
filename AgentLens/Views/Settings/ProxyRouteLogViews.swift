import OpenBurnBarCore
import SwiftUI

struct ProxyRouteLogSheet: View {
    let entries: [BurnBarProxyRouteLogEntry]
    let state: ProxyRouteLogState
    let onRefresh: (() -> Void)?
    let onClear: (() -> Void)?

    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 34, height: 34)
                    .background(DesignSystem.Colors.ember.opacity(0.12))
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent proxy routes")
                        .font(DesignSystem.Typography.headline)
                        .fontWeight(.semibold)
                    Text(statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .help(state == .clearing ? "Clearing route log" : "Loading route log")
                }
                if let onClear {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isBusy || entries.isEmpty)
                    .confirmationDialog(
                        "Clear the route log?",
                        isPresented: $showClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear route log", role: .destructive) { onClear() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently removes the locally recorded proxy routes. It does not change routing — only the history you're viewing here.")
                    }
                }
                if let onRefresh {
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isBusy)
                }
            }
            .padding(DesignSystem.Spacing.lg)

            Divider()

            Group {
                switch state {
                case .loading where entries.isEmpty, .clearing where entries.isEmpty:
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ProgressView()
                        Text(state == .clearing ? "Clearing route log" : "Loading route log")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message, _):
                    ProxyRouteLogEmptyState(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Route log unavailable",
                        message: message,
                        tint: DesignSystem.Colors.error
                    )
                case .idle where entries.isEmpty,
                     .loaded where entries.isEmpty:
                    ProxyRouteLogEmptyState(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: "No proxy routes recorded yet",
                        message: "Send a request through the local gateway, then refresh.",
                        tint: DesignSystem.Colors.textMuted
                    )
                default:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            ForEach(entries) { entry in
                                ProxyRouteLogRow(entry: entry)
                            }
                        }
                        .padding(DesignSystem.Spacing.lg)
                    }
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .background(DesignSystem.Colors.background)
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "Shows exactly what OpenBurnBar selected and sent upstream."
        case .loading:
            return "Loading from the local daemon socket."
        case .clearing:
            return "Clearing local route metadata."
        case .loaded(let lastRefresh):
            return "\(entries.count) route\(entries.count == 1 ? "" : "s") loaded. Last refresh \(lastRefresh.formatted(date: .omitted, time: .shortened))."
        case .error(_, let lastAttempt):
            return "Last attempt \(lastAttempt.formatted(date: .omitted, time: .shortened))."
        }
    }
}

private struct ProxyRouteLogEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
            Text(message)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProxyRouteLogRow: View {
    let entry: BurnBarProxyRouteLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                modelBlock(title: "Requested", slug: entry.clientModelSlug, name: entry.clientModelDisplayName)
                Image(systemName: isMismatch ? "arrow.right" : "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isMismatch ? statusTint : DesignSystem.Colors.success)
                    .frame(width: 22, height: 34)
                    .accessibilityHidden(true)
                modelBlock(
                    title: "Proxy sent",
                    slug: entry.upstreamModelSlug ?? entry.routingModelSlug ?? "no-route",
                    name: entry.upstreamModelDisplayName ?? entry.routingModelDisplayName,
                    providerID: entry.providerID,
                    providerName: entry.providerName,
                    emphasizeMismatch: isMismatch
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    statusChip
                    if entry.exactModelInvariant == .failed || entry.exactModelInvariant == .unavailable {
                        identityBadge
                    }
                    Text(entry.occurredAt.formatted(date: .omitted, time: .standard))
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            if let reported = entry.providerReportedModelSlug {
                if providerReportedMismatch {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Provider reported \(reported) — differs from proxy sent")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(DesignSystem.Colors.error)
                } else {
                    Text("Provider reported \(reported)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(metadataText)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(2)

            if entry.attempts.count > 1 {
                ForEach(entry.attempts) { attempt in
                    Text("#\(attempt.sequence) \(attempt.providerName) → \(attempt.upstreamModelSlug) (\(attempt.status.rawValue.replacingOccurrences(of: "_", with: " ")))")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(attemptTint(for: attempt.status))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let failure = entry.failureMessage {
                Text(failure)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(statusTint.opacity(isMismatch ? 0.1 : 0))
                )
        )
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(statusTint.opacity(isMismatch ? 0.5 : 0.22), lineWidth: isMismatch ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(statusTint)
                .frame(width: 3)
                .padding(.vertical, 8)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func modelBlock(
        title: String,
        slug: String,
        name: String?,
        providerID: String? = nil,
        providerName: String? = nil,
        emphasizeMismatch: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            ZStack(alignment: .bottomTrailing) {
                ModelProviderLogoView(modelKey: slug, size: 30)
                if let providerID, let providerName {
                    ProxyProviderLogoView(catalogProviderID: providerID, providerName: providerName, size: 16)
                        .background(Circle().fill(DesignSystem.Colors.surface))
                        .offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(name ?? slug)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(emphasizeMismatch ? statusTint : DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Text(slug)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let providerName {
                    Text(providerName)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 240, alignment: .leading)
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Image(systemName: statusImage)
                .font(.system(size: 9, weight: .bold))
            Text(statusLabel)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(statusTint)
        .background(statusTint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var isMismatch: Bool {
        entry.finalStatus != .exact
    }

    /// Per-attempt tint in the expanded attempt list. Exhaustive so a new
    /// status case cannot silently render with the neutral secondary style.
    private func attemptTint(for status: BurnBarProxyRouteFinalStatus) -> Color {
        switch status {
        case .failed:
            return DesignSystem.Colors.error
        case .interrupted:
            // Interrupted attempts are amber, matching the row chip: the
            // stream broke mid-flight, but the route was not at fault.
            return DesignSystem.Colors.warning
        case .exact, .sameModelFailover, .crossVendorFallback, .rejected:
            return DesignSystem.Colors.textSecondary
        }
    }

    private var providerReportedMismatch: Bool {
        guard let reported = entry.providerReportedModelSlug else { return false }
        return reported != entry.upstreamModelSlug
    }

    private var identityTint: Color {
        entry.exactModelInvariant == .failed ? DesignSystem.Colors.error : DesignSystem.Colors.warning
    }

    private var identityBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 9, weight: .bold))
            Text(entry.exactModelInvariant == .failed ? "Identity failed" : "Identity unverified")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(identityTint)
        .background(identityTint.opacity(0.14))
        .clipShape(Capsule())
    }

    /// One spoken sentence for VoiceOver. The row collapses its many fragments
    /// (requested, sent, slugs, chips, timestamp) into a single statement so the
    /// "Opus did not actually go to Opus" relationship is conveyed, not just the
    /// disconnected pieces.
    private var accessibilitySummary: String {
        let requested = entry.clientModelDisplayName ?? entry.clientModelSlug
        let sentSlug = entry.upstreamModelSlug ?? entry.routingModelSlug ?? "no route"
        let sent = entry.upstreamModelDisplayName ?? entry.routingModelDisplayName ?? sentSlug
        var parts: [String] = ["Requested \(requested)", "proxy sent \(sent)", statusLabel]
        if let provider = entry.providerName { parts.append("via \(provider)") }
        if entry.exactModelInvariant == .failed { parts.append("identity check failed") }
        if providerReportedMismatch, let reported = entry.providerReportedModelSlug {
            parts.append("provider reported \(reported), which differs from what was sent")
        }
        if let failure = entry.failureMessage { parts.append(failure) }
        return parts.joined(separator: ", ")
    }

    private var metadataText: String {
        let usage = entry.usage.map {
            "\($0.inputTokens) in / \($0.outputTokens) out / $\($0.cost.formatted(.number.precision(.fractionLength(4))))"
        }
        return [
            entry.requestPath,
            entry.streamed ? (entry.streamInterrupted ? "stream interrupted" : "streamed") : "buffered",
            entry.accountLabel.map { "account \($0)" },
            entry.httpStatus.map { "HTTP \($0)" },
            usage
        ].compactMap { $0 }.joined(separator: "  ")
    }

    private var statusLabel: String {
        ProxyRouteStatusPresentation(status: entry.finalStatus).label
    }

    private var statusImage: String {
        ProxyRouteStatusPresentation(status: entry.finalStatus).systemImage
    }

    private var statusTint: Color {
        ProxyRouteStatusPresentation(status: entry.finalStatus).tone.color
    }
}

/// Single source of truth for how a proxy-route final status is presented.
/// Exhaustive over `BurnBarProxyRouteFinalStatus` on purpose — a new status
/// case must fail this switch at compile time instead of silently falling
/// through to some default rendering.
struct ProxyRouteStatusPresentation: Equatable {
    /// Semantic tone, resolved to a concrete `DesignSystem` token by `color`.
    /// Kept as a separate enum so unit tests can pin the semantics without
    /// comparing SwiftUI `Color` values.
    enum Tone: Equatable {
        case success
        case warning
        case error
        case muted

        var color: Color {
            switch self {
            case .success: return DesignSystem.Colors.success
            case .warning: return DesignSystem.Colors.warning
            case .error: return DesignSystem.Colors.error
            case .muted: return DesignSystem.Colors.textMuted
            }
        }
    }

    let label: String
    let systemImage: String
    let tone: Tone

    init(status: BurnBarProxyRouteFinalStatus) {
        switch status {
        case .exact:
            label = "Exact"
            systemImage = "checkmark.seal.fill"
            tone = .success
        // Same-model failover is benign — you still got the model you asked for,
        // just from another account — so it stays amber. Cross-vendor fallback is
        // the dangerous "Opus actually went to GLM" case this whole view exists to
        // surface, so it gets the loud error treatment, not a shared amber.
        case .sameModelFailover:
            label = "Same model failover"
            systemImage = "arrow.triangle.branch"
            tone = .warning
        case .crossVendorFallback:
            label = "Cross-vendor fallback"
            systemImage = "exclamationmark.triangle.fill"
            tone = .error
        case .failed:
            label = "Failed"
            systemImage = "xmark.octagon.fill"
            tone = .error
        case .rejected:
            label = "No route"
            systemImage = "minus.circle.fill"
            tone = .muted
        // Interrupted is not a failure: bytes were flowing and the stream ended
        // early (client hang-up or upstream drop). The request is retryable and
        // the route stayed healthy, so it reads as amber, never failure-red.
        case .interrupted:
            label = "Interrupted"
            systemImage = "waveform.path.ecg"
            tone = .warning
        }
    }
}
