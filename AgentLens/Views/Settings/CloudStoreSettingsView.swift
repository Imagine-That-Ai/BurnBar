import SwiftUI
import AppKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions

// MARK: - Cloud Store Settings View (macOS)
//
// macOS variant of the OpenBurnBar Cloud destination. Lives inside the
// Settings window under the new "Cloud" pane. macOS does not yet have a
// StoreKit purchase flow wired (the SKU is universal but the macOS app is
// still beta) — so the CTA opens the iOS App Store listing so the user can
// purchase on iPhone, where the entitlement then propagates back to this
// machine via the Cloud Functions entitlement doc.
//
// Same Pro vocabulary as iOS: ProPosterScaffold + MercuryFoilCard + serif
// hero + FoilCTAButton. A member who buys on iPhone walks here and finds
// the same world.

struct CloudStoreSettingsView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var remoteMCPClients = MacRemoteMCPClientStore()

    var body: some View {
        ProPosterScaffold {
            ScrollView {
                VStack(spacing: 28) {
                    hero
                        .padding(.horizontal, 28)
                        .padding(.top, 24)

                    planCard
                        .padding(.horizontal, 28)

                    capabilityLineup
                        .padding(.horizontal, 28)

                    remoteMCPCard
                        .padding(.horizontal, 28)

                    trustCard
                        .padding(.horizontal, 28)

                    Spacer(minLength: 36)
                }
            }
        }
        .navigationTitle("OpenBurnBar Cloud")
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            MercuryCrest(size: .large, shimmer: !reduceMotion)

            VStack(spacing: 6) {
                Text("OPENBURNBAR")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.6)
                    .foregroundStyle(ProTheme.Palette.aureate)

                Text("Cloud")
                    .font(ProTheme.Typography.displaySerif)
                    .foregroundStyle(ProTheme.Palette.mercury)

                Text("Your agents, unbound — hosted refresh, conversation backup, Hermes anywhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Plan card

    private var planCard: some View {
        MercuryFoilCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MEMBERSHIP")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(ProTheme.Palette.aureate)
                    Spacer()
                    Text("MONTHLY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(ProTheme.Palette.mercury)
                        .background(
                            Capsule().fill(ProTheme.Palette.obsidianElevated)
                        )
                        .overlay(
                            Capsule().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.7)
                        )
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$4.99")
                        .font(ProTheme.Typography.priceMono)
                        .foregroundStyle(ProTheme.Palette.mercury)
                    Text("/ month")
                        .font(.system(size: 13))
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.65))
                }

                Text("Apple-verified, billed monthly via the App Store. Manage or cancel anytime in Settings → Apple ID.")
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)

                FoilCTAButton(
                    title: "Continue on iPhone",
                    subtitle: "Subscribe in the iOS app — entitlement lands here automatically.",
                    icon: "iphone"
                ) {
                    if let url = URL(string: "https://apps.apple.com/app/id6766366964") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Link("Open pricing on openburnbar.com", destination: URL(string: "https://openburnbar.com/pricing")!)
                    .font(.system(size: 11))
                    .foregroundStyle(ProTheme.Palette.aureate)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Capability lineup

    private var capabilityLineup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT'S INCLUDED")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Spacer()
            }

            VStack(spacing: 12) {
                capabilityRow(
                    icon: "cloud.fill",
                    title: "Hosted Codex quota",
                    detail: "Refresh Codex quota from any signed-in device. We run the runner; you get the dial."
                )
                capabilityRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Conversation backup & resume",
                    detail: "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off."
                )
                capabilityRow(
                    icon: "text.alignleft",
                    title: "Full session-log sync",
                    detail: "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device."
                )
                capabilityRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Hermes remote relay",
                    detail: "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end."
                )
            }
        }
    }

    // MARK: - Remote MCP

    private var remoteMCPCard: some View {
        MercuryFoilCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("REMOTE MCP", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(ProTheme.Palette.aureate)
                    Spacer()
                    Label("BurnBar Pro", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ProTheme.Palette.aureate)
                }

                Text("Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP uses the hosted endpoint; the local shim keeps decrypted snippets on-device.")
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)

                remoteMCPCommandRow(label: "Endpoint", value: "https://mcp.openburnbar.com/mcp")
                remoteMCPCommandRow(label: "Stdio shim", value: "openburnbar-mcp-remote mcp serve")
                remoteMCPCommandRow(label: "Doctor", value: "openburnbar mcp doctor")

                MacRemoteMCPConnectedClientsSection(store: remoteMCPClients)

                Link(destination: URL(string: "https://openburnbar.com/docs/remote-mcp")!) {
                    HStack(spacing: 6) {
                        Text("Open Remote MCP setup")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.aureate)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { remoteMCPClients.startListening() }
        .onDisappear { remoteMCPClients.stopListening() }
    }

    private func remoteMCPCommandRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ProTheme.Palette.mercury)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ProTheme.Palette.obsidianElevated.opacity(0.86))
                )
        }
    }

    private func capabilityRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(ProTheme.Palette.obsidianElevated)
                Circle().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.9)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ProTheme.Palette.aureate)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ProTheme.Typography.headlineSerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .fill(ProTheme.Palette.obsidianElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.7)
        )
    }

    // MARK: - Trust

    private var trustCard: some View {
        MercuryFoilCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("THE TRUST MODEL")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Palette.aureate)

                trustBullet(
                    icon: "checkmark.shield.fill",
                    title: "Apple-verified",
                    detail: "Every transaction JWS is checked against Apple's root certificates server-side."
                )
                trustBullet(
                    icon: "server.rack",
                    title: "UID-bound",
                    detail: "Each purchase is bound to your Firebase UID via a signed appAccountToken."
                )
                trustBullet(
                    icon: "hand.raised.fill",
                    title: "Cancel anytime",
                    detail: "Managed by Apple in Settings → Apple ID. We never store payment details."
                )

                Link(destination: URL(string: "https://openburnbar.com/cloud")!) {
                    HStack(spacing: 6) {
                        Text("Read the Hosted Quota Sync technical doc")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.aureate)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trustBullet(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ProTheme.Typography.headlineSerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MacRemoteMCPClientRecord: Identifiable, Hashable {
    let id: String
    let displayName: String
    let clientType: String
    let allowedScopes: [String]
    let grantMode: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let revokedAt: Date?

    var isRevoked: Bool { revokedAt != nil }

    var displayType: String {
        clientType.isEmpty ? "generic MCP" : clientType
    }

    var scopeSummary: String {
        allowedScopes.isEmpty ? "No scopes recorded" : allowedScopes.sorted().joined(separator: ", ")
    }

    var modeSummary: String {
        switch grantMode {
        case "sealed_only": return "Sealed only"
        case "local_decrypt_shim": return "Local decrypt shim"
        case "remote_readable_explicit_opt_in": return "Remote readable opt-in"
        default: return grantMode.isEmpty ? "Local decrypt shim" : grantMode.replacingOccurrences(of: "_", with: " ")
        }
    }

    var activitySummary: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let lastUsedAt {
            return "Used \(formatter.localizedString(for: lastUsedAt, relativeTo: Date()))"
        }
        if let createdAt {
            return "Added \(formatter.localizedString(for: createdAt, relativeTo: Date()))"
        }
        return "Awaiting first use"
    }
}

@MainActor
private final class MacRemoteMCPClientStore: ObservableObject {
    @Published private(set) var clients: [MacRemoteMCPClientRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var revokingClientID: String?

    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?

    deinit {
        listener?.remove()
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
    }

    func startListening() {
        guard FirebaseApp.app() != nil else {
            clients = []
            error = "Cloud is not configured on this Mac."
            return
        }

        if authHandle == nil {
            authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                Task { @MainActor in
                    self?.restartListener(uid: user?.uid)
                }
            }
        }

        restartListener(uid: Auth.auth().currentUser?.uid)
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        isLoading = false
    }

    func revoke(_ client: MacRemoteMCPClientRecord) async {
        guard !client.isRevoked else { return }
        revokingClientID = client.id
        error = nil
        do {
            let callable = Functions.functions(region: "us-central1").httpsCallable("revokeRemoteMcpClient")
            _ = try await callable.call(["clientId": client.id])
        } catch {
            self.error = error.localizedDescription
        }
        revokingClientID = nil
    }

    private func restartListener(uid: String?) {
        listener?.remove()
        listener = nil
        error = nil
        guard let uid else {
            clients = []
            isLoading = false
            error = "Sign in to view connected MCP clients."
            return
        }

        isLoading = true
        listener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("remote_mcp_clients")
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = false
                    if let error {
                        self.clients = []
                        self.error = error.localizedDescription
                        return
                    }
                    self.clients = (snapshot?.documents ?? [])
                        .compactMap { Self.decode(documentID: $0.documentID, data: $0.data()) }
                        .sorted { lhs, rhs in
                            (lhs.lastUsedAt ?? lhs.createdAt ?? .distantPast) > (rhs.lastUsedAt ?? rhs.createdAt ?? .distantPast)
                        }
                }
            }
    }

    private static func decode(documentID: String, data: [String: Any]) -> MacRemoteMCPClientRecord {
        let clientID = (data["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientType = (data["clientType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = data["allowedScopes"] as? [String] ?? []
        let grantMode = (data["grantMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MacRemoteMCPClientRecord(
            id: clientID?.isEmpty == false ? clientID! : documentID,
            displayName: displayName?.isEmpty == false ? displayName! : "OpenBurnBar MCP client",
            clientType: clientType ?? "",
            allowedScopes: scopes,
            grantMode: grantMode ?? "local_decrypt_shim",
            createdAt: date(from: data["createdAt"]),
            lastUsedAt: date(from: data["lastUsedAt"]),
            revokedAt: date(from: data["revokedAt"])
        )
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }
}

private struct MacRemoteMCPConnectedClientsSection: View {
    @ObservedObject var store: MacRemoteMCPClientStore
    @State private var pendingRevoke: MacRemoteMCPClientRecord?
    @State private var isConfirmingRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connected clients", systemImage: "rectangle.connected.to.line.below")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProTheme.Palette.mercury)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.clients.isEmpty && !store.isLoading {
                Text("No MCP clients are connected yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.62))
            } else {
                ForEach(store.clients) { client in
                    MacRemoteMCPClientRow(
                        client: client,
                        isRevoking: store.revokingClientID == client.id,
                        onRevoke: {
                            pendingRevoke = client
                            isConfirmingRevoke = true
                        }
                    )
                }
            }
        }
        .confirmationDialog("Revoke MCP client?", isPresented: $isConfirmingRevoke, titleVisibility: .visible) {
            if let pendingRevoke {
                Button("Revoke \(pendingRevoke.displayName)", role: .destructive) {
                    Task { await store.revoke(pendingRevoke) }
                }
            }
        } message: {
            if let pendingRevoke {
                Text("This immediately blocks \(pendingRevoke.displayName) and revokes its outstanding grants.")
            }
        }
    }
}

private struct MacRemoteMCPClientRow: View {
    let client: MacRemoteMCPClientRecord
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                MacRemoteMCPClientStatusIcon(isRevoked: client.isRevoked)
                MacRemoteMCPClientDetails(client: client)

                Spacer(minLength: 8)

                MacRemoteMCPClientRevokeAction(
                    displayName: client.displayName,
                    isRevoked: client.isRevoked,
                    isRevoking: isRevoking,
                    onRevoke: onRevoke
                )
            }

            MacRemoteMCPClientActivityText(text: client.activitySummary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ProTheme.Palette.obsidianElevated.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowStrokeColor, lineWidth: 0.5)
        )
    }

    private var rowStrokeColor: Color {
        client.isRevoked ? ProTheme.Palette.mercury.opacity(0.24) : ProTheme.Palette.aureate.opacity(0.28)
    }
}

private struct MacRemoteMCPClientStatusIcon: View {
    let isRevoked: Bool

    var body: some View {
        Image(systemName: isRevoked ? "xmark.seal.fill" : "checkmark.seal.fill")
            .foregroundColor(isRevoked ? ProTheme.Palette.mercury.opacity(0.42) : ProTheme.Palette.aureate)
            .padding(.top, 2)
    }
}

private struct MacRemoteMCPClientDetails: View {
    let client: MacRemoteMCPClientRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(client.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ProTheme.Palette.mercury)
            Text("\(client.displayType) · \(client.modeSummary)")
                .font(.system(size: 11))
                .foregroundColor(ProTheme.Palette.mercury.opacity(0.70))
            Text(client.scopeSummary)
                .font(.system(size: 10))
                .foregroundColor(ProTheme.Palette.mercury.opacity(0.54))
        }
    }
}

private struct MacRemoteMCPClientRevokeAction: View {
    let displayName: String
    let isRevoked: Bool
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        if isRevoked {
            Text("Revoked")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(ProTheme.Palette.mercury.opacity(0.48))
        } else {
            Button(action: onRevoke) {
                buttonContent
            }
            .buttonStyle(.plain)
            .foregroundColor(.red.opacity(0.88))
            .disabled(isRevoking)
            .accessibilityLabel("Revoke \(displayName)")
        }
    }

    @ViewBuilder
    private var buttonContent: some View {
        if isRevoking {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "xmark.circle.fill")
        }
    }
}

private struct MacRemoteMCPClientActivityText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(ProTheme.Palette.mercury.opacity(0.54))
    }
}

#Preview("Cloud Store Settings (macOS)") {
    CloudStoreSettingsView()
        .frame(width: 720, height: 600)
}
