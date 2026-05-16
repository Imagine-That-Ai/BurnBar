import SwiftUI
import OpenBurnBarCore

/// iOS Mercury attachment bubble — shown in the chat thread when a peer
/// (or the local user) attaches a file. Mirror of the Mac
/// `AttachmentChipRow`. For image MIME types, Phase 2 surfaces an inline
/// thumbnail; non-image types render the SF Symbol glyph.
@MainActor
struct AttachmentBubble: View {
    enum State: Equatable {
        case inFlight(progress: Double)
        case complete(localFileURL: URL?)
        case error(message: String)
    }

    let manifest: HermesRealtimeRelayAttachmentManifest
    let state: State
    let onPreview: () -> Void
    let onSavePhotos: () -> Void
    let onSaveFiles: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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

                Spacer(minLength: 0)
            }

            switch state {
            case .inFlight(let progress):
                LinearProgressBar(progress: progress)
                    .frame(height: 2)
            case .complete(let localURL):
                HStack(spacing: 8) {
                    if localURL != nil {
                        Button("Preview", action: onPreview).buttonStyle(.borderedProminent)
                    }
                    if AttachmentSaver.isPhotoCandidate(mime: manifest.mime) {
                        Button("Photos", action: onSavePhotos)
                    }
                    Button("Files", action: onSaveFiles)
                    Spacer()
                }
                .font(.callout)
            case .error:
                Button("Retry", action: onRetry).buttonStyle(.bordered).font(.callout)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderGradient, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if case .complete(let url) = state,
           let url, AttachmentSaver.isPhotoCandidate(mime: manifest.mime),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.accentColor.opacity(0.15)
                Image(systemName: glyph)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(iconColor)
            }
        }
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
