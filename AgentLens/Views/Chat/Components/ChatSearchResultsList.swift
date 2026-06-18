import SwiftUI

struct ChatSearchResultsList: View {
    var results: [SearchResult]
    var onSelect: (SearchResult) -> Void

    @State private var hovered: SearchResult.ID?

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
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.3))
                            }
                        }
                        .liquidGlassSurface(in: RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous), fallback: .thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [Color.white.opacity(hovered == r.id ? 0.2 : 0.1), DesignSystem.Colors.border.opacity(hovered == r.id ? 0.5 : 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
                    .animation(DesignSystem.Animation.hover, value: hovered)
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
