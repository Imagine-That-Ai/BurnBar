import SwiftUI

struct ChatSearchResultsList: View {
    var results: [SearchResult]
    var onSelect: (SearchResult) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(results) { r in
                    Button {
                        onSelect(r)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.conversation.inferredTaskTitle)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(2)
                            Text(r.snippet.strippingSimpleTags)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(2)
                            Text("\(r.conversation.provider.displayName) · \(r.conversation.projectName)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Spacing.sm)
                        .background {
                            ZStack {
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(.thinMaterial)
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.3))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.1), DesignSystem.Colors.border.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }
}

private extension String {
    var strippingSimpleTags: String {
        replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
    }
}
