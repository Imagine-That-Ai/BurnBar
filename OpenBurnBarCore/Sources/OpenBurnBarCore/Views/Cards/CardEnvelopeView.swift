import SwiftUI

// MARK: - Card Envelope View (Hermes Square §6.6)
//
// Single dispatch view that picks the right per-kind renderer for any
// `CardEnvelope`. Host wraps this in its own chrome (typography +
// palette + drag-handle) — the per-kind views below stay chrome-free so
// they compose under any surface (inbox, brand zone, mission tile,
// situation room).

public struct CardEnvelopeView: View {
    public let envelope: CardEnvelope
    public let agentAccent: Color
    public let onApprovalChoice: ((CardApproval.Option) -> Void)?
    public let onCustomAction: ((String) -> Void)?

    public init(
        envelope: CardEnvelope,
        agentAccent: Color = DesignSystemColors.ember,
        onApprovalChoice: ((CardApproval.Option) -> Void)? = nil,
        onCustomAction: ((String) -> Void)? = nil
    ) {
        self.envelope = envelope
        self.agentAccent = agentAccent
        self.onApprovalChoice = onApprovalChoice
        self.onCustomAction = onCustomAction
    }

    public var body: some View {
        switch envelope {
        case .text(let p):     CardTextView(payload: p)
        case .table(let p):    CardTableView(payload: p)
        case .diff(let p):     CardDiffView(payload: p, accent: agentAccent)
        case .image(let p):    CardImageView(payload: p)
        case .chart(let p):    CardChartView(payload: p, accent: agentAccent)
        case .approval(let p): CardApprovalView(payload: p, accent: agentAccent, onChoice: onApprovalChoice)
        case .mission(let p):  CardMissionRefView(payload: p, accent: agentAccent)
        case .custom(let p):   CardCustomView(payload: p, accent: agentAccent, onAction: onCustomAction)
        case .tooLarge(let p): CardTooLargeView(payload: p)
        case .unknown(let s):  CardUnknownView(label: s)
        }
    }
}

// MARK: - Text

public struct CardTextView: View {
    public let payload: CardText
    public init(payload: CardText) { self.payload = payload }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Use `LocalizedStringKey` so the system parses markdown inline
            // bold / italic / links without us building our own renderer.
            Text(LocalizedStringKey(payload.markdown))
                .font(.body)
                .foregroundStyle(DesignSystemColors.textPrimary)
                .textSelection(.enabled)
            if let footnote = payload.footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Table

public struct CardTableView: View {
    public let payload: CardTable
    public init(payload: CardTable) { self.payload = payload }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = payload.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider().background(DesignSystemColors.borderSubtle)
                    ForEach(Array(payload.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 12) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(DesignSystemColors.textPrimary)
                                    .frame(minWidth: 60, alignment: .leading)
                                    .padding(.vertical, 4)
                            }
                        }
                        .padding(.horizontal, 8)
                        .background(DesignSystemColors.surfaceElevated.opacity(0.4))
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(payload.headers.enumerated()), id: \.offset) { _, h in
                Text(h)
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                    .frame(minWidth: 60, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 8)
        .background(DesignSystemColors.surface)
    }
}

// MARK: - Diff

public struct CardDiffView: View {
    public let payload: CardDiff
    public let accent: Color
    public init(payload: CardDiff, accent: Color) {
        self.payload = payload
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.caption2)
                    .foregroundStyle(accent)
                Text(payload.file)
                    .font(.caption.monospaced())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                if let lang = payload.language {
                    Text(lang)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(accent.opacity(0.18))
                        )
                        .foregroundStyle(accent)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    diffColumn(label: "Before", text: payload.before, tint: DesignSystemColors.error.opacity(0.18))
                    diffColumn(label: "After",  text: payload.after,  tint: DesignSystemColors.success.opacity(0.18))
                }
            }
        }
    }

    private func diffColumn(label: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(DesignSystemColors.textMuted)
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(DesignSystemColors.textPrimary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(tint)
                )
                .frame(minWidth: 220, alignment: .leading)
        }
    }
}

// MARK: - Image

public struct CardImageView: View {
    public let payload: CardImage
    public init(payload: CardImage) { self.payload = payload }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = URL(string: payload.url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystemColors.surface)
                            .frame(height: CGFloat(payload.heightHint ?? 180))
                            .overlay(ProgressView())
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystemColors.surface)
                            .frame(height: 80)
                            .overlay(
                                Text("Image unavailable")
                                    .font(.caption)
                                    .foregroundStyle(DesignSystemColors.textMuted)
                            )
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            if !payload.alt.isEmpty {
                Text(payload.alt)
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
    }
}

// MARK: - Chart

public struct CardChartView: View {
    public let payload: CardChart
    public let accent: Color
    public init(payload: CardChart, accent: Color) {
        self.payload = payload
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(accent)
                Text(payload.format == .vegaLite ? "Vega-Lite chart" : "InsightWidget chart")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
            }
            // Real renderer is layered on per platform; the package-level
            // view is a tasteful stub that lists the spec keys so a host
            // without a chart engine still shows something editorial. Per
            // §6.6 the host decides — text-only hosts surface this stub.
            Text(payload.spec)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(DesignSystemColors.textMuted)
                .lineLimit(8)
                .truncationMode(.tail)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignSystemColors.surface)
                )
        }
    }
}

// MARK: - Approval

public struct CardApprovalView: View {
    public let payload: CardApproval
    public let accent: Color
    public let onChoice: ((CardApproval.Option) -> Void)?
    public init(payload: CardApproval, accent: Color, onChoice: ((CardApproval.Option) -> Void)?) {
        self.payload = payload
        self.accent = accent
        self.onChoice = onChoice
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(payload.prompt)
                .font(.body.bold())
                .foregroundStyle(DesignSystemColors.textPrimary)
            if let detail = payload.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(DesignSystemColors.textSecondary)
            }
            HStack(spacing: 8) {
                ForEach(payload.options) { option in
                    Button {
                        onChoice?(option)
                    } label: {
                        Text(option.label)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(background(for: option.kind))
                            )
                            .foregroundStyle(foreground(for: option.kind))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(accent.opacity(0.35), lineWidth: 0.5)
                )
        )
    }

    private func background(for kind: CardApproval.Option.Kind) -> Color {
        switch kind {
        case .primary:      return accent
        case .secondary:    return DesignSystemColors.surface
        case .destructive:  return DesignSystemColors.error.opacity(0.18)
        }
    }
    private func foreground(for kind: CardApproval.Option.Kind) -> Color {
        switch kind {
        case .primary:      return .white
        case .secondary:    return DesignSystemColors.textPrimary
        case .destructive:  return DesignSystemColors.error
        }
    }
}

// MARK: - Mission ref

public struct CardMissionRefView: View {
    public let payload: CardMissionRef
    public let accent: Color
    public init(payload: CardMissionRef, accent: Color) {
        self.payload = payload
        self.accent = accent
    }
    public var body: some View {
        // The host wires a live MissionConsoleSnapshot lookup; the
        // package-level stub renders an editorial placeholder.
        HStack(spacing: 10) {
            Image(systemName: "doc.viewfinder")
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mission")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Text(payload.missionID)
                    .font(.caption.monospaced())
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystemColors.surface)
        )
    }
}

// MARK: - Custom (sandbox stub)

public struct CardCustomView: View {
    public let payload: CardCustom
    public let accent: Color
    public let onAction: ((String) -> Void)?
    public init(payload: CardCustom, accent: Color, onAction: ((String) -> Void)?) {
        self.payload = payload
        self.accent = accent
        self.onAction = onAction
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(accent)
                Text("Mini-program")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
            }
            Text("This card needs the sandboxed mini-program host. Phase C ships the runtime.")
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textMuted)
            Button {
                onAction?(payload.sandboxURL)
            } label: {
                Text("Open in sandbox")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.4), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
        )
    }
}

// MARK: - Too large

public struct CardTooLargeView: View {
    public let payload: CardTooLarge
    public init(payload: CardTooLarge) { self.payload = payload }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystemColors.warning)
                Text("Card payload too large")
                    .font(.caption.bold())
            }
            Text("This \(payload.kindAttempted) card was \(formatted(payload.attemptedBytes)) — over the \(formatted(payload.maxBytes)) budget. The agent should reshape it.")
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textMuted)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystemColors.warning.opacity(0.12))
        )
    }

    private func formatted(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        if bytes >= 1024       { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }
}

// MARK: - Unknown

public struct CardUnknownView: View {
    public let label: String
    public init(label: String) { self.label = label }
    public var body: some View {
        Text("Unsupported card: \(label)")
            .font(.caption)
            .foregroundStyle(DesignSystemColors.textMuted)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignSystemColors.borderSubtle, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            )
    }
}
