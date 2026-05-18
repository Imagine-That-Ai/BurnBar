import SwiftUI
import OpenBurnBarCore

/// Mercury attachment row used by the Mac chat thread. Three states —
/// in-flight, complete, error — all wrapped in `ChatBubbleStyle.toolShape`
/// with a 1pt `mercuryGradient` stroke. Mirrors the iOS `AttachmentBubble`
/// so a screenshot from one platform looks indistinguishable from the
/// other.
///
/// See `plans/2026-05-15-mercury-media-master-plan.md` § E.3.
@MainActor
struct AttachmentChipRow: View {
    enum State: Equatable {
        case inFlight(progress: Double)
        case complete
        case error(message: String)
    }

    let manifest: HermesRealtimeRelayAttachmentManifest
    let state: State
    let onOpen: () -> Void
    let onSavePhotos: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: glyph)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.filename)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(secondaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                trailingControls
            }

            if case .inFlight(let progress) = state {
                LinearProgressBar(progress: progress)
                    .frame(height: 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderGradient, lineWidth: 1)
        )
    }

    private var glyph: String {
        switch state {
        case .error: return "exclamationmark.triangle"
        default:
            switch manifest.mime {
            case "application/pdf": return "doc.richtext"
            case let mime where mime.hasPrefix("image/"): return "photo"
            case let mime where mime.hasPrefix("video/"): return "film"
            case "text/plain", "application/json": return "doc.text"
            default: return "paperclip"
            }
        }
    }

    private var iconColor: Color {
        switch state {
        case .error: return Color.red
        default: return Color.accentColor
        }
    }

    private var borderGradient: LinearGradient {
        switch state {
        case .error:
            return LinearGradient(colors: [Color.red.opacity(0.7), Color.red.opacity(0.4)], startPoint: .leading, endPoint: .trailing)
        default:
            return LinearGradient(
                colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var secondaryLine: String {
        switch state {
        case .inFlight(let progress):
            return "\(formattedSize) · \(Int(progress * 100))%"
        case .complete:
            return formattedSize
        case .error(let message):
            return message
        }
    }

    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: manifest.size)
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch state {
        case .complete:
            HStack(spacing: 6) {
                Button("Open", action: onOpen).buttonStyle(.borderless)
                Button("Save", action: onSavePhotos).buttonStyle(.borderless)
            }
            .font(.callout)
        case .error:
            Button("Retry", action: onRetry).buttonStyle(.borderless).font(.callout)
        case .inFlight:
            EmptyView()
        }
    }
}

private struct LinearProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.78, green: 0.74, blue: 0.69), Color(red: 0.63, green: 0.67, blue: 0.73)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
            }
        }
    }
}
