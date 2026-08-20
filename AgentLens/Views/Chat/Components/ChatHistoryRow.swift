import SwiftUI
import OpenBurnBarCore

/// Row representing a chat thread summary. Shared by the floating panel's
/// menu popover, the maximized workspace thread rail, and the pop-out window.
struct ChatHistoryRow: View {
    enum PaneRailBadge: Equatable {
        case none
        case openInPane
        case unseen
    }

    let thread: ChatThreadSummary
    let isActive: Bool
    /// True when this thread is open in a (non-active) tiling pane — drawn as a subtle
    /// "open in a pane" hint so the rail shows which conversations are tiled.
    var isOpenInPane: Bool = false
    var paneBadge: PaneRailBadge = .none
    var accent: Color = DesignSystem.Colors.whimsy

    /// Neutral, and correct on both grounds without a branch: `Color.primary`
    /// inverts with the theme, so these three numbers are a light wash on dark
    /// and a dark wash on light.
    private var rowWash: Double {
        if isActive { return 0.085 }
        if effectivePaneBadge != .none { return 0.05 }
        return 0.025
    }
    let onSelect: () -> Void

    private var effectivePaneBadge: PaneRailBadge {
        paneBadge != .none ? paneBadge : (isOpenInPane ? .openInPane : .none)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                    } else if effectivePaneBadge == .unseen {
                        PaneStatusDot(color: accent)
                            .help("Pane completed")
                    } else if effectivePaneBadge == .openInPane {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.7))
                            .help("Open in a pane")
                    }
                }

                Text(HermesAtomParser.plainText(thread.preview))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)

                MacAttachmentSummaryStrip(attachments: thread.attachments)

                Text("\(thread.messageCount) msgs · \(thread.lastActivityAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.sm)
            .background {
                // Selection reads as a *lit* row, not a tinted one. The old
                // fill painted the selected thread in the answering agent's
                // hue, which put up to twelve different colours down one rail
                // depending on who replied last — the rail became a legend for
                // a key nobody was reading.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(rowWash))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isActive ? 0.12 : 0), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

struct MacAttachmentSummaryStrip: View {
    let attachments: [HermesAttachment]

    var body: some View {
        if !attachments.isEmpty {
            HStack(spacing: 5) {
                ForEach(attachments.prefix(3)) { attachment in
                    MacAttachmentSummaryChip(attachment: attachment)
                }
                if attachments.count > 3 {
                    Text("+\(attachments.count - 3)")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attachments: \(attachments.map(\.displayName).joined(separator: ", "))")
        }
    }
}

private struct MacAttachmentSummaryChip: View {
    let attachment: HermesAttachment

    var body: some View {
        HStack(spacing: 5) {
            thumbnail
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.leading, 4)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.58))
                .overlay(Capsule(style: .continuous).stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5))
        )
        .frame(maxWidth: 124)
    }

    private var label: String {
        if let text = attachment.extractedTextPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return attachment.displayName
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = attachment.thumbnailPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignSystem.Colors.surfaceElevated.opacity(0.72)))
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
