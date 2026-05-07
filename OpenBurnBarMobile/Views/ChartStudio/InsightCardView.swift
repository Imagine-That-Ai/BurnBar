import SwiftUI

// MARK: - Insight Card View
//
// Renders a Hermes-authored narrative insight (title + body + optional
// sparkline) as a glass card. Used directly by Chart Studio when the AI
// returns `kind: "insight"`.

struct InsightCardView: View {
    let spec: InsightSpec
    let onAskFollowUp: ((String) -> Void)?

    init(spec: InsightSpec, onAskFollowUp: ((String) -> Void)? = nil) {
        self.spec = spec
        self.onAskFollowUp = onAskFollowUp
    }

    var body: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 8) {
                    Image(systemName: toneIcon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(toneColor)
                    Text("INSIGHT")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(1.6)
                        .foregroundStyle(toneColor)
                    Spacer()
                }

                Text(spec.title)
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text(spec.body)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let sparkline = spec.sparkline, sparkline.count > 1 {
                    EmberSparkline(values: sparkline)
                        .frame(height: 56)
                }

                if let onAskFollowUp {
                    Button {
                        onAskFollowUp("Show me the chart that proves \"\(spec.title)\"")
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.system(size: 11, weight: .bold))
                            Text("Show me the chart")
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.aurora(.hermes))
                    .padding(.top, 4)
                }
            }
        }
    }

    private var toneColor: Color {
        switch spec.tone?.lowercased() {
        case "positive": return MobileTheme.success
        case "warning":  return MobileTheme.warning
        default:         return MobileTheme.hermesAureate
        }
    }

    private var toneIcon: String {
        switch spec.tone?.lowercased() {
        case "positive": return "checkmark.seal.fill"
        case "warning":  return "exclamationmark.triangle.fill"
        default:         return "sparkles"
        }
    }
}
