import SwiftUI
import StoreKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

private enum CloudStoreLegalURLs {
    static let privacy = URL(string: "https://openburnbar.com/legal/privacy-policy")!
    static let terms = URL(string: "https://openburnbar.com/legal/terms")!
}

private enum CloudSubscriptionDisclosure {
    static let title = "OpenBurnBar Cloud Monthly"
    static let period = "1 month, auto-renews monthly"
    static let included = "Hosted Codex quota refresh, Conversation Backup & Resume, Full Session-Log Sync, Hermes Remote Relay, and Hosted Remote MCP."
    static let billing = "Billed by Apple. Auto-renews until canceled at least 24 hours before renewal. Manage or cancel in Settings -> Apple ID."
}

// MARK: - Cloud Store View — Pro Poster
//
// The Pro destination. Wears the "luxury island in utilitarian sea"
// vocabulary — obsidian + mercury foil + serif display — deliberately
// distinct from the daily-driver Aurora shell. The whole surface composes
// from `ProTheme`, `ProPosterScaffold`, `MercuryFoilCard`, `MercuryCrest`,
// and `FoilCTAButton` so members who land here from any whisper or moment
// arrive in a coherent world.
//
// Surfaces:
//   • Free   — serif hero, MercuryFoilCard plan tile, capability lineup,
//              comparison, trust, foil CTA action bar.
//   • Member — serif hero, MercuryCrest + member certificate card,
//              capability lineup (with checks), comparison, trust, no CTA.
//
// Reads the shared store from `@Environment(\.cloudSubscriptionStore)`;
// falls back to a screen-local instance for previews and deep-link entry.

struct CloudStoreView: View {

    var onClose: (() -> Void)? = nil

    @Environment(\.cloudSubscriptionStore) private var sharedStore
    @Environment(\.dismiss) private var dismiss
    @State private var localStore = HostedQuotaSubscriptionStore()
    @State private var didLoadLocal = false
    @StateObject private var remoteMCPClients = RemoteMCPClientStore()

    private var store: HostedQuotaSubscriptionStore {
        sharedStore ?? localStore
    }

    var body: some View {
        ProPosterScaffold {
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    CloudStorePosterHero(store: store)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .settingsAnchor(SettingsAnchor.cloudMembership)
                        .staggeredEntrance(delay: 0.0)

                    if store.isActive {
                        CloudStoreMemberCard(store: store)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .settingsAnchor(SettingsAnchor.cloudPlan)
                            .staggeredEntrance(delay: 0.05)
                    } else {
                        CloudStorePlanTile(store: store)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .settingsAnchor(SettingsAnchor.cloudPlan)
                            .staggeredEntrance(delay: 0.05)
                    }

                    CloudStoreCapabilityLineup(isActive: store.isActive)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.10)

                    CloudStoreRemoteMCPCard(isActive: store.isActive, clientStore: remoteMCPClients)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.13)

                    CloudStoreComparisonCard()
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.17)

                    CloudStoreTrustCard()
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.21)

                    if !store.isActive {
                        CloudStoreSubscriptionDetails(
                            priceText: store.product?.displayPrice ?? "$4.99"
                        )
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.23)
                    }

                    if let error = store.error {
                        CloudStoreErrorCard(message: error)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.top, MobileTheme.Spacing.md)
                .padding(.bottom, store.isActive ? MobileTheme.Spacing.xl : 160)
            }
            .settingsAnchor(SettingsAnchor.cloudRow)

            if !store.isActive {
                CloudStoreActionBar(store: store)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .settingsAnchor(SettingsAnchor.cloudRestore)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("OpenBurnBar Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if onClose != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onClose?()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ProTheme.Palette.mercury.opacity(0.78))
                            .frame(width: 30, height: 30)
                            .background(ProTheme.Palette.obsidianElevated, in: Circle())
                            .overlay(
                                Circle().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.7)
                            )
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            if sharedStore == nil, !didLoadLocal {
                didLoadLocal = true
                await localStore.load()
            }
        }
        .animation(MobileTheme.Animation.gentle, value: store.isActive)
        .animation(MobileTheme.Animation.gentle, value: store.error)
    }
}

// MARK: - Hero

private struct CloudStorePosterHero: View {
    let store: HostedQuotaSubscriptionStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            MercuryCrest(size: .large, shimmer: !reduceMotion)
                .padding(.top, MobileTheme.Spacing.lg)

            VStack(spacing: MobileTheme.Spacing.xs) {
                Text("OPENBURNBAR")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(3.6)
                    .foregroundStyle(ProTheme.Palette.aureate)

                Text("Cloud")
                    .font(ProTheme.Typography.displaySerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
                    .accessibilityAddTraits(.isHeader)

                Text(tagline)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var tagline: String {
        if store.isActive {
            return "Your agents, unbound. Renewing on schedule."
        }
        return "Your agents, unbound — hosted refresh, conversation backup, Hermes anywhere."
    }
}

// MARK: - Plan Tile (free state)

private struct CloudStorePlanTile: View {
    let store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("MEMBERSHIP")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Spacer(minLength: 0)
                Text("MONTHLY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(ProTheme.Palette.mercury)
                    .background(
                        Capsule().fill(ProTheme.Palette.obsidianElevated)
                    )
                    .overlay(
                        Capsule().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.7)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.product?.displayPrice ?? "$4.99")
                        .font(ProTheme.Typography.priceMono)
                        .foregroundStyle(ProTheme.Palette.mercury)
                    Text("/ month")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.65))
                }
                Text("OpenBurnBar Cloud — Apple-verified, billed monthly. Cancel anytime in Settings → Apple ID.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenBurnBar Cloud monthly plan, \(store.product?.displayPrice ?? "$4.99") per month. Billed by Apple, cancel anytime.")
    }
}

/// Wraps any content in the MercuryFoilCard chrome without needing the
/// generic view-builder closure — used here so we can attach a single
/// background/border to the plan tile content.
private struct MercuryFoilCardModifier: ViewModifier {
    var cornerRadius: CGFloat = ProTheme.Layout.cardRadius

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var specularPhase: CGFloat = -1.4
    @State private var didFireSpecular = false

    func body(content: Content) -> some View {
        content
            .background(backgroundLayers)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ProTheme.Palette.aureateStroke, lineWidth: ProTheme.Layout.foilStroke)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: ProTheme.Palette.aureate.opacity(0.20), radius: 18, y: 8)
            .onAppear(perform: fireSpecularIfNeeded)
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(ProTheme.Palette.obsidian)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            ProTheme.Palette.aureate.opacity(0.10),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 360
                    )
                )
                .blendMode(.plusLighter)
            if !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .opacity(0.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fireSpecularIfNeeded() {
        guard !reduceMotion, !didFireSpecular else { return }
        didFireSpecular = true
        specularPhase = -1.4
        withAnimation(ProTheme.Motion.specular.delay(0.15)) {
            specularPhase = 1.4
        }
    }
}

// MARK: - Capability Lineup

private struct CloudStoreCapabilityLineup: View {
    let isActive: Bool

    private struct Capability {
        let icon: String
        let title: String
        let detail: String
    }

    private let capabilities: [Capability] = [
        .init(
            icon: "cloud.fill",
            title: "Hosted Codex quota",
            detail: "Refresh Codex quota from any signed-in device. We run the runner; you get the dial."
        ),
        .init(
            icon: "arrow.triangle.2.circlepath",
            title: "Conversation backup & resume",
            detail: "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off."
        ),
        .init(
            icon: "text.alignleft",
            title: "Full session-log sync",
            detail: "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device."
        ),
        .init(
            icon: "antenna.radiowaves.left.and.right",
            title: "Hermes remote relay",
            detail: "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT'S INCLUDED")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Spacer()
                if isActive {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
            }

            VStack(spacing: MobileTheme.Spacing.md) {
                ForEach(Array(capabilities.enumerated()), id: \.offset) { _, cap in
                    CloudStoreCapabilityCard(
                        icon: cap.icon,
                        title: cap.title,
                        detail: cap.detail,
                        isActive: isActive
                    )
                }
            }
        }
    }
}

private struct CloudStoreCapabilityCard: View {
    let icon: String
    let title: String
    let detail: String
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle().fill(ProTheme.Palette.obsidianElevated)
                Circle().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.9)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ProTheme.Palette.aureate)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(ProTheme.Typography.headlineSerif)
                        .foregroundStyle(ProTheme.Palette.mercury)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ProTheme.Palette.aureate)
                    }
                }
                Text(detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                    .fill(ProTheme.Palette.obsidianElevated)
                if !reduceMotion {
                    MercuryShimmerOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous))
                        .blendMode(.plusLighter)
                        .opacity(0.30)
                        .allowsHitTesting(false)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(isActive ? ", active" : ""). \(detail)")
    }
}

// MARK: - Remote MCP

private struct RemoteMCPClientRecord: Identifiable, Hashable {
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
}

@MainActor
private final class RemoteMCPClientStore: ObservableObject {
    @Published private(set) var clients: [RemoteMCPClientRecord] = []
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
            error = "Cloud is not configured on this device."
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

    func revoke(_ client: RemoteMCPClientRecord) async {
        guard !client.isRevoked else { return }
        revokingClientID = client.id
        error = nil
        do {
            try await FunctionsRepository.shared.revokeRemoteMcpClient(clientID: client.id)
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

    private static func decode(documentID: String, data: [String: Any]) -> RemoteMCPClientRecord {
        let clientID = (data["clientId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientType = (data["clientType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = data["allowedScopes"] as? [String] ?? []
        let grantMode = (data["grantMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return RemoteMCPClientRecord(
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

private struct CloudStoreRemoteMCPCard: View {
    let isActive: Bool
    @ObservedObject var clientStore: RemoteMCPClientStore

    private let endpoint = "https://mcp.openburnbar.com/mcp"
    private let stdioCommand = "openburnbar-mcp-remote mcp serve"
    private let doctorCommand = "openburnbar mcp doctor"

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Label("REMOTE MCP", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Spacer()
                Label(isActive ? "Included" : "Cloud only",
                      systemImage: isActive ? "checkmark.seal.fill" : "lock.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(isActive ? ProTheme.Palette.aureate : ProTheme.Palette.mercury.opacity(0.65))
            }

            Text("Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP for hosted clients; a local shim keeps decrypted snippets on-device for stdio.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                RemoteMCPCommandRow(label: "Endpoint", value: endpoint)
                RemoteMCPCommandRow(label: "Stdio shim", value: stdioCommand)
                RemoteMCPCommandRow(label: "Doctor", value: doctorCommand)
            }

            if isActive {
                RemoteMCPConnectedClientsSection(store: clientStore)
            }

            HStack(spacing: MobileTheme.Spacing.md) {
                Link(destination: URL(string: "https://openburnbar.com/docs/remote-mcp")!) {
                    Label("Setup", systemImage: "arrow.up.right.square.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
                Link(destination: URL(string: "https://openburnbar.com/docs/remote-mcp-runbook")!) {
                    Label("Runbook", systemImage: "stethoscope")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote MCP. \(isActive ? "Included with your subscription." : "Requires OpenBurnBar Cloud.") Endpoint \(endpoint). Stdio shim \(stdioCommand). Doctor \(doctorCommand).")
        .onAppear {
            if isActive {
                clientStore.startListening()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                clientStore.startListening()
            } else {
                clientStore.stopListening()
            }
        }
        .onDisappear {
            clientStore.stopListening()
        }
    }
}

private struct RemoteMCPConnectedClientsSection: View {
    @ObservedObject var store: RemoteMCPClientStore
    @State private var pendingRevoke: RemoteMCPClientRecord?
    @State private var isConfirmingRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack {
                Label("Connected clients", systemImage: "rectangle.connected.to.line.below")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(ProTheme.Palette.mercury)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ProTheme.Palette.aureate)
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.clients.isEmpty && !store.isLoading {
                Text("No MCP clients are connected yet.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.clients) { client in
                    RemoteMCPClientRow(
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
        .padding(.top, MobileTheme.Spacing.xs)
        .confirmationDialog(
            "Revoke MCP client?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
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

private struct RemoteMCPClientRow: View {
    let client: RemoteMCPClientRecord
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                Image(systemName: client.isRevoked ? "xmark.seal.fill" : "checkmark.seal.fill")
                    .foregroundStyle(client.isRevoked ? ProTheme.Palette.mercury.opacity(0.42) : ProTheme.Palette.aureate)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(ProTheme.Palette.mercury)
                        .lineLimit(2)
                    Text("\(client.displayType) · \(client.modeSummary)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.70))
                        .lineLimit(2)
                    Text(client.scopeSummary)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.54))
                        .lineLimit(2)
                }

                Spacer(minLength: MobileTheme.Spacing.sm)

                if client.isRevoked {
                    Text("Revoked")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.48))
                } else {
                    Button(role: .destructive, action: onRevoke) {
                        if isRevoking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.88))
                    .accessibilityLabel("Revoke \(client.displayName)")
                    .disabled(isRevoking)
                }
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
                if let lastUsedAt = client.lastUsedAt {
                    Label("Used \(lastUsedAt, style: .relative)", systemImage: "clock.arrow.circlepath")
                } else if let createdAt = client.createdAt {
                    Label("Added \(createdAt, style: .relative)", systemImage: "plus.circle")
                } else {
                    Label("Awaiting first use", systemImage: "clock")
                }
            }
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(ProTheme.Palette.mercury.opacity(0.54))
        }
        .padding(MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(ProTheme.Palette.obsidianElevated.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(
                    client.isRevoked
                        ? AnyShapeStyle(ProTheme.Palette.aureateStroke.opacity(0.35))
                        : AnyShapeStyle(ProTheme.Palette.aureate.opacity(0.28)),
                    lineWidth: 0.5
                )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteMCPCommandRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ProTheme.Palette.mercury)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
                .padding(.horizontal, MobileTheme.Spacing.sm)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                        .fill(ProTheme.Palette.obsidianElevated.opacity(0.85))
                )
        }
    }
}

// MARK: - Comparison

private struct CloudStoreComparisonCard: View {
    private struct Row: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let free: String
        let cloud: String
    }

    private let rows: [Row] = [
        Row(label: "Quota refresh",       free: "Local-only",       cloud: "On-demand, anywhere"),
        Row(label: "Chat backup",         free: "Metadata only",    cloud: "Full content"),
        Row(label: "Session logs",        free: "Manifest only",    cloud: "Search metadata"),
        Row(label: "Hermes Remote Relay", free: "Local network",    cloud: "Anywhere"),
        Row(label: "Remote MCP",          free: "Local helper",     cloud: "Hosted endpoint")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FREE VS CLOUD")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(ProTheme.Palette.aureate)
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
                .padding(.bottom, MobileTheme.Spacing.sm)

            VStack(spacing: 0) {
                headerRow
                Divider().background(ProTheme.Palette.aureate.opacity(0.35))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    comparisonRow(row)
                    if index < rows.count - 1 {
                        Divider().background(ProTheme.Palette.mercury.opacity(0.18))
                    }
                }
            }
        }
        .padding(.bottom, MobileTheme.Spacing.md)
        .modifier(MercuryFoilCardModifier())
    }

    private var headerRow: some View {
        HStack {
            Text("Capability")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.0)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("FREE")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
                .frame(width: 90, alignment: .trailing)
            Text("CLOUD")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.4)
                .foregroundStyle(ProTheme.Palette.aureate)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
    }

    private func comparisonRow(_ row: Row) -> some View {
        HStack {
            Text(row.label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(ProTheme.Palette.mercury)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.free)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
                .frame(width: 90, alignment: .trailing)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Text(row.cloud)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(ProTheme.Palette.mercury)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label). Free: \(row.free). Cloud: \(row.cloud).")
    }
}

// MARK: - Trust

private struct CloudStoreTrustCard: View {
    private let bullets: [(String, String, String)] = [
        ("checkmark.shield.fill", "Apple-verified", "Every transaction JWS is checked against Apple's root certificates server-side."),
        ("server.rack",            "UID-bound",     "Each purchase is bound to your Firebase UID via a signed appAccountToken."),
        ("hand.raised.fill",       "Cancel anytime","Managed by Apple in Settings → Apple ID. We never store payment details.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("THE TRUST MODEL")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(ProTheme.Palette.aureate)

            ForEach(bullets, id: \.1) { item in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                    Image(systemName: item.0)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ProTheme.Palette.aureate)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1)
                            .font(ProTheme.Typography.headlineSerif)
                            .foregroundStyle(ProTheme.Palette.mercury)
                        Text(item.2)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(ProTheme.Palette.mercury.opacity(0.70))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                Link(destination: URL(string: "https://openburnbar.com/cloud")!) {
                    HStack(spacing: 6) {
                        Text("Read the Hosted Quota Sync technical doc")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.aureate)
                }
                CloudStoreLegalLinks(alignment: .leading)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
    }
}

// MARK: - Subscription Details (free state — Apple disclosure)

private struct CloudStoreSubscriptionDetails: View {
    let priceText: String

    private var rows: [(String, String)] {
        [
            ("Service", CloudSubscriptionDisclosure.title),
            ("Length", CloudSubscriptionDisclosure.period),
            ("Price", "\(priceText) per month"),
            ("Includes", CloudSubscriptionDisclosure.included),
            ("Billing", CloudSubscriptionDisclosure.billing)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("SUBSCRIPTION DETAILS")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(ProTheme.Palette.aureate)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .tracking(1.0)
                            .foregroundStyle(ProTheme.Palette.mercury.opacity(0.55))
                        Text(row.1)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(ProTheme.Palette.mercury)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
        .accessibilityIdentifier("cloudStore.subscriptionDisclosure")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subscription details. \(CloudSubscriptionDisclosure.title). \(CloudSubscriptionDisclosure.period). \(priceText) per month. Includes \(CloudSubscriptionDisclosure.included) \(CloudSubscriptionDisclosure.billing)")
    }
}

// MARK: - Action Bar (free state)

private struct CloudStoreActionBar: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            FoilCTAButton(
                title: "Become a Member",
                subtitle: subtitleLine,
                icon: "sparkles",
                isLoading: store.isLoading
            ) {
                Task { await store.purchase() }
            }
            .disabled(store.product == nil)

            HStack(spacing: MobileTheme.Spacing.md) {
                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    Text("Restore Purchases")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(ProTheme.Palette.mercury.opacity(0.7))
                }
                .disabled(store.isLoading)
                .accessibilityIdentifier("cloudStore.restoreLink")

                Spacer(minLength: 0)

                CloudStoreLegalLinks(alignment: .trailing)
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.md)
        .padding(.bottom, MobileTheme.Spacing.lg)
        .background(
            LinearGradient(
                colors: [
                    ProTheme.Palette.obsidian.opacity(0.0),
                    ProTheme.Palette.obsidian.opacity(0.90),
                    ProTheme.Palette.obsidian.opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    private var subtitleLine: String {
        let price = store.product?.displayPrice ?? "$4.99"
        return "\(price) / month · Apple-verified, billed monthly"
    }
}

// MARK: - Legal Links

private struct CloudStoreLegalLinks: View {
    enum AlignmentMode: Equatable {
        case center
        case leading
        case trailing
    }

    var alignment: AlignmentMode = .center

    var body: some View {
        HStack(spacing: 8) {
            Link("Privacy", destination: CloudStoreLegalURLs.privacy)
                .accessibilityIdentifier("cloudStore.privacyPolicyLink")
            Text("·")
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.5))
            Link("Terms", destination: CloudStoreLegalURLs.terms)
                .accessibilityIdentifier("cloudStore.termsOfUseLink")
        }
        .font(MobileTheme.Typography.tiny)
        .foregroundStyle(ProTheme.Palette.aureate)
        .frame(maxWidth: alignment == .trailing ? nil : .infinity,
               alignment: stackAlignment)
        .accessibilityElement(children: .contain)
    }

    private var stackAlignment: Alignment {
        switch alignment {
        case .center:   return .center
        case .leading:  return .leading
        case .trailing: return .trailing
        }
    }
}

// MARK: - Member Card
//
// The "certificate" surface. Renders for active subscribers. Mercury foil
// border, animated shimmer + amber sparks, member-since date, manage +
// restore actions. Kept from the previous design — already lives in the
// Pro vocabulary.

private struct CloudStoreMemberCard: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backgroundLayers

            VStack(spacing: MobileTheme.Spacing.lg) {
                laurelHeader
                renewalLine
                memberMetaLine
                actionRow
            }
            .padding(MobileTheme.Spacing.xl)
        }
        .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous)
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: 1.2)
        )
        .shadow(color: ProTheme.Palette.aureate.opacity(0.25), radius: 24, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var laurelHeader: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "laurel.leading")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureateStroke)
            VStack(spacing: 2) {
                Text("CLOUD")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(3.0)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Text("Member")
                    .font(ProTheme.Typography.titleSerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
            }
            Image(systemName: "laurel.trailing")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureateStroke)
        }
    }

    private var renewalLine: some View {
        Group {
            if let expiration = store.expirationDate {
                Label {
                    Text("Renews \(expiration, style: .relative)")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(ProTheme.Palette.mercury)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
            } else {
                Label {
                    Text("Active")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(ProTheme.Palette.mercury)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
            }
        }
    }

    private var memberMetaLine: some View {
        Group {
            if let purchaseDate = store.purchaseDate {
                Text("Member since \(purchaseDate, format: .dateTime.month(.abbreviated).year())")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.65))
            } else if let exp = store.expirationDate {
                Text("Through \(exp, format: .dateTime.month(.abbreviated).day().year())")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.65))
            } else {
                EmptyView()
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                    Text("Manage")
                        .fontWeight(.semibold)
                }
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(ProTheme.Palette.obsidian)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(ProTheme.Palette.aureateStroke)
                )
            }
            .accessibilityLabel("Manage subscription in App Store")

            Button {
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: 6) {
                    if store.isLoading {
                        MiningPickLoader(.inline, tint: ProTheme.Palette.mercury)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Restore")
                        .fontWeight(.semibold)
                }
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(ProTheme.Palette.mercury)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(ProTheme.Palette.obsidianElevated)
                        .overlay(
                            Capsule().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.7)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .settingsAnchor(SettingsAnchor.cloudRestore)
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous)
                .fill(ProTheme.Palette.obsidian)
            RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ProTheme.Palette.aureate.opacity(0.16),
                            UnifiedDesignSystem.Colors.ember.opacity(0.10),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RadialGradient(
                colors: [
                    ProTheme.Palette.aureate.opacity(0.28),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 240
            )
            .blendMode(.plusLighter)

            if !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)

                MemberSparksOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.cardRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                    .opacity(0.55)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = ["OpenBurnBar Cloud member"]
        if let exp = store.expirationDate {
            parts.append("Renews \(exp.formatted(.relative(presentation: .named)))")
        }
        if let purchase = store.purchaseDate {
            let fmt = purchase.formatted(.dateTime.month(.wide).year())
            parts.append("Member since \(fmt)")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Member Sparks Overlay

private struct MemberSparksOverlay: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let count = 8
                for i in 0..<count {
                    let seed = Double(i) * 1.234
                    let phase = (t * 0.22 + seed).truncatingRemainder(dividingBy: 1.0)
                    let x = size.width * (0.10 + ((sin(seed * 5.7) + 1) * 0.40))
                    let yStart = size.height * 0.95
                    let yEnd = size.height * 0.20
                    let y = yStart + (yEnd - yStart) * CGFloat(phase)
                    let radius: CGFloat = 1.4
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.opacity = (1.0 - phase) * 0.6
                    let color: Color = (i % 2 == 0)
                        ? UnifiedDesignSystem.Colors.amber
                        : ProTheme.Palette.aureate
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Error Card

private struct CloudStoreErrorCard: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.error)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(MobileTheme.Colors.error)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.error.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.error.opacity(0.45), lineWidth: 0.5)
        )
    }
}

// MARK: - Previews

#Preview("Locked") {
    NavigationStack {
        CloudStoreView()
    }
}
