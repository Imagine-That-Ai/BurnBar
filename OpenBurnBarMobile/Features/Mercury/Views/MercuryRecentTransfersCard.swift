import SwiftUI
import QuickLook
#if canImport(UIKit)
import UIKit
#endif

/// Glassmorphic card showing up to 5 most recent transfers (both sent +
/// received) for the active connection. Tap → QuickLook for received
/// files; ShareSheet for sent. Long-press → context menu with Remove
/// and Send Again.
struct MercuryRecentTransfersCard: View {
    let entries: [MercuryTransferHistoryEntry]
    let totalCount: Int
    let accent: Color
    let onRemove: (MercuryTransferHistoryEntry) -> Void
    let onSendAnother: () -> Void

    @State private var quickLookURL: URL?

    var body: some View {
        if entries.isEmpty {
            // Empty state collapses to a single thin pill so it doesn't
            // dominate the screen before the user has sent anything.
            HStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("No transfers yet")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer(minLength: 6)
                Button(action: onSendAnother) {
                    Text("Send a file")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.28)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial.opacity(0.65))
                    .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No transfers yet")
        } else {
            populatedCard
        }
    }

    @ViewBuilder
    private var populatedCard: some View {
        VStack(spacing: 14) {
            header

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    TransferRow(
                        entry: entry,
                        accent: accent,
                        onTap: { handleTap(entry) },
                        onRemove: { onRemove(entry) }
                    )
                    if index < entries.count - 1 {
                        Divider().background(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .quickLookPreview($quickLookURL)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent transfers")
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            Text("Recent Transfers")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if totalCount > entries.count {
                Text("+\(totalCount - entries.count) more")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        EmptyView()
    }

    private func handleTap(_ entry: MercuryTransferHistoryEntry) {
        guard let url = entry.localURL else { return }
        switch entry.direction {
        case .received:
            quickLookURL = url
        case .sent:
            // Best-effort — sent files were picked from outside our sandbox,
            // and security-scoped resource access expires once the file
            // importer dismisses. We still try a QuickLook; if it fails the
            // sheet quietly does nothing rather than throwing.
            quickLookURL = url
        }
    }
}

private struct TransferRow: View {
    let entry: MercuryTransferHistoryEntry
    let accent: Color
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(entry.direction == .sent ? 0.22 : 0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: entry.direction.arrowIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.filename)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Text(entry.direction.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(accent.opacity(0.9))
                        Text("·")
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text(formattedSize(entry.sizeBytes))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text("·")
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text(relativeTime(entry.completedAt))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Spacer(minLength: 8)

                if entry.looksLikeImage, let thumbnail = thumbnailImage() {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.direction.displayName) \(entry.filename), \(formattedSize(entry.sizeBytes)), \(relativeTime(entry.completedAt))")
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func thumbnailImage() -> UIImage? {
        #if canImport(UIKit)
        guard let url = entry.localURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
        #else
        return nil
        #endif
    }
}
