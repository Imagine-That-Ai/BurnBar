import SwiftUI
import OpenBurnBarCore

// MARK: - Chat Attachment Tray (mobile)

/// Horizontally-scrollable strip of attachment chips used by the chat
/// composer to show pending attachments before send.
struct ChatAttachmentTray: View {
    let attachments: [HermesAttachment]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                ForEach(attachments) { attachment in
                    ChatAttachmentChip(attachment: attachment, onRemove: { onRemove(attachment.id) })
                }
            }
            .padding(.vertical, MobileTheme.Spacing.xs)
        }
    }
}

// MARK: - Chat Attachment Chip

struct ChatAttachmentChip: View {
    let attachment: HermesAttachment
    /// `nil` renders a non-interactive transcript chip (no close button).
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(MobileTheme.Typography.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(metaText)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.displayName)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 220)
    }

    private var metaText: String {
        let size = HermesAttachmentEncoder.formatBytes(attachment.byteSize)
        let kindLabel: String
        switch attachment.kind {
        case .image: kindLabel = "image"
        case .pdf: kindLabel = "PDF"
        case .audio: kindLabel = "audio"
        case .video: kindLabel = "video"
        case .textDocument: kindLabel = "text"
        case .generic: kindLabel = "file"
        }
        return "\(kindLabel) · \(size)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumb = attachment.thumbnailPNG, let uiImage = UIImage(data: thumb) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MobileTheme.Colors.surface)
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MobileTheme.hermesAureate)
            }
            .frame(width: 32, height: 32)
        }
    }

    private var iconName: String {
        switch attachment.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "play.rectangle"
        case .textDocument: return "doc.text"
        case .generic: return "doc"
        }
    }
}

// MARK: - Chat Bubble Attachment Strip (transcript-side)

/// Compact strip of attachment chips shown above a user bubble in the
/// transcript so the conversation history shows what was attached.
struct ChatBubbleAttachmentStrip: View {
    let attachments: [HermesAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    ChatAttachmentChip(attachment: attachment, onRemove: nil)
                }
            }
        }
    }
}
