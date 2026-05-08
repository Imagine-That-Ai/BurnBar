import SwiftUI
import OpenBurnBarCore

// MARK: - Chat Attachment Tray (macOS)

/// Horizontally-scrolling chip strip rendered above the chat composer
/// whenever attachments are staged on a message (live composer) or already
/// attached to a sent transcript row.
struct ChatAttachmentTray: View {
    var attachments: [HermesAttachment]
    var isHermes: Bool
    var attachmentError: String? = nil
    /// `nil` for read-only transcript rows.
    var onRemove: ((String) -> Void)? = nil
    /// Called when the user clicks a chip to reveal it in Finder.
    var onReveal: ((HermesAttachment) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = attachmentError, !error.isEmpty {
                Text(error)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .padding(.horizontal, DesignSystem.Spacing.md)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(attachments) { attachment in
                            ChatAttachmentChip(
                                attachment: attachment,
                                isHermes: isHermes,
                                onRemove: onRemove,
                                onReveal: onReveal
                            )
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }
}

private struct ChatAttachmentChip: View {
    let attachment: HermesAttachment
    let isHermes: Bool
    let onRemove: ((String) -> Void)?
    let onReveal: ((HermesAttachment) -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            iconOrThumb
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.displayName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                Text("\(HermesAttachmentEncoder.formatBytes(attachment.byteSize)) · ~\(attachment.estimatedTokenCost) tok")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            if let onRemove {
                Button {
                    onRemove(attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Remove attachment")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(hovering ? 0.95 : 0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(strokeStyle, lineWidth: 0.75)
        )
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            onReveal?(attachment)
        }
        .contextMenu {
            if let onReveal {
                Button("Reveal in Finder") { onReveal(attachment) }
            }
            if let onRemove {
                Button("Remove") { onRemove(attachment.id) }
            }
        }
    }

    private var strokeStyle: AnyShapeStyle {
        if isHermes {
            return AnyShapeStyle(DesignSystem.Colors.mercuryGradient.opacity(0.55))
        }
        return AnyShapeStyle(DesignSystem.Colors.whimsy.opacity(0.55))
    }

    @ViewBuilder
    private var iconOrThumb: some View {
        if let png = attachment.thumbnailPNG, let nsImage = NSImage(data: png) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.7))
                Image(systemName: kindIcon(attachment.kind))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private func kindIcon(_ kind: HermesAttachmentKind) -> String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .textDocument: return "doc.text"
        case .audio: return "waveform"
        case .video: return "film"
        case .generic: return "doc"
        }
    }
}
