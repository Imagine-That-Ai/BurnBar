import SwiftUI
import AppKit
import OpenBurnBarCore
import OpenBurnBarMedia

/// Menu-bar popover Mercury section. Live indicator, paired-iPhone
/// label, and outbound triggers (Call iPhone / Send File). Renders
/// inside the existing `GlassCard` envelope so it inherits the
/// popover's material + hairline language.
///
/// Reads from:
///   • `MercuryRouter.phase` for the streaming indicator and Cooldown
///     countdown.
///   • `MercuryPeerSource.peer` for online/offline + display name.
///   • `MercuryConsentStore.alwaysAllow` for the "auto-accept my
///     iPhone" disclosure toggle.
///
/// Side-effects:
///   • "Call iPhone" → `VoIPCallTrigger.trigger`.
///   • "Send File…" → `NSOpenPanel` → `MacFileTransferService.sendFile`.
///   • "End mirror" (visible during `.streaming`) → `MercuryRouter.stopMirror`.
@MainActor
struct MercuryTraySection: View {
    @ObservedObject var router: MercuryRouter
    @ObservedObject var peerSource: MercuryPeerSource
    let fileTransferService: MacFileTransferService?
    let voipCallTrigger: VoIPCallTrigger?
    let consentStore: MercuryConsentStore?
    let uidProvider: @MainActor () -> String?
    let onDismissPopover: () -> Void

    @State private var isShowingFilePicker = false
    @State private var lastError: String?
    @State private var sendingFile = false

    private var peer: MercuryPeer? { peerSource.peer }
    private var isStreaming: Bool {
        if case .streaming = router.phase { return true }
        return false
    }
    private var isCooldown: Bool {
        if case .cooldown = router.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            phaseLine
            actionRow
            if let consentStore {
                Toggle(isOn: Binding(
                    get: { consentStore.alwaysAllow },
                    set: { consentStore.alwaysAllow = $0 }
                )) {
                    Text("Always allow my iPhone to mirror this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Always allow my iPhone to mirror this Mac")
            }
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Mercury error: \(lastError)")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(borderGradient, lineWidth: 0.75)
                )
        )
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onCompletion: { result in
                Task { await handleFilePick(result) }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mercury")
        .accessibilityValue(accessibilityValue)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MercuryRing(isActive: isStreaming)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer?.displayName ?? "Mercury")
                    .font(.system(size: 13, weight: .semibold))
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            availabilityDot
        }
    }

    private var availabilityDot: some View {
        let online = peer?.isOnline ?? false
        return Circle()
            .fill(online ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 7, height: 7)
            .accessibilityLabel(online ? "iPhone online" : "iPhone offline")
    }

    @ViewBuilder
    private var phaseLine: some View {
        switch router.phase {
        case .idle:
            EmptyView()
        case .ringing(_, let name, _):
            Text("\(name) is asking to mirror")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting mirror…")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        case .streaming(_, let since):
            Text("streaming · \(formattedDuration(since: since))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.63, green: 0.67, blue: 0.73))
        case .cooldown(let seconds):
            Text("cooling down · \(seconds)s")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if isStreaming {
                Button(role: .destructive) {
                    Task { await router.stopMirror() }
                } label: {
                    Label("End", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .accessibilityLabel("End mirror")
            } else {
                Button {
                    Task { await placeCall() }
                } label: {
                    Label("Call", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.63, green: 0.67, blue: 0.73))
                .controlSize(.small)
                .disabled(peer?.canPlaceCall != true || voipCallTrigger == nil)
                .accessibilityLabel("Call paired iPhone")
            }

            Button {
                isShowingFilePicker = true
            } label: {
                Label(sendingFile ? "Sending…" : "Send", systemImage: "paperclip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.63, green: 0.67, blue: 0.73))
            .controlSize(.small)
            .disabled(peer?.canSendFile != true || sendingFile || fileTransferService == nil)
            .accessibilityLabel("Send file to paired iPhone")
        }
    }

    private var statusLine: String {
        if let peer, peer.isOnline {
            return "Connected via iroh"
        }
        if peer != nil {
            return "Offline · waiting for iPhone"
        }
        return "No paired iPhone"
    }

    private var accessibilityValue: String {
        let phaseLabel: String
        switch router.phase {
        case .idle: phaseLabel = "Idle"
        case .ringing: phaseLabel = "Incoming mirror request"
        case .starting: phaseLabel = "Starting mirror"
        case .streaming: phaseLabel = "Mirroring"
        case .cooldown(let s): phaseLabel = "Cooling down \(s) seconds"
        }
        return "\(statusLine), \(phaseLabel)"
    }

    private func formattedDuration(since: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(since))
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        let h = elapsed / 3600
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func placeCall() async {
        guard let trigger = voipCallTrigger,
              let peer,
              peer.canPlaceCall else { return }
        // VoIP trigger requires a real PushKit token. v1 of this UI
        // wires the affordance and surfaces an honest error when no
        // token has been cached — Phase 5b will plumb the token reader.
        lastError = "Call requires a paired iPhone PushKit token; not yet wired."
        _ = trigger
    }

    private func handleFilePick(_ result: Result<[URL], Error>) async {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(err) = result {
                lastError = err.localizedDescription
            }
            return
        }
        guard let service = fileTransferService, let peer else {
            lastError = "File transfer not available."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            lastError = "Sign in to send files."
            return
        }
        sendingFile = true
        defer { sendingFile = false }
        do {
            _ = try await service.sendFile(
                at: url,
                uid: uid,
                connectionID: peer.connectionID,
                peerDeviceID: peer.connectionID
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.78, green: 0.74, blue: 0.69),
                Color(red: 0.63, green: 0.67, blue: 0.73)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
