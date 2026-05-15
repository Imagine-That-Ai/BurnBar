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
    @State private var presentedCapability: CloudCapability?
    @StateObject private var remoteMCPClients = RemoteMCPClientStore()

    private var store: HostedQuotaSubscriptionStore {
        sharedStore ?? localStore
    }

    var body: some View {
        ZStack {
            EmberSurfaceBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    CloudStorePosterHero(store: store)
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

                    CloudStoreCapabilityLineup(isActive: store.isActive) { cap in
                        presentedCapability = cap
                    }
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
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
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
        .sheet(item: $presentedCapability) { cap in
            NavigationStack {
                CapabilityDetailSheet(
                    capability: cap,
                    ctaLabel: store.isActive ? "Manage Cloud" : "Become a Member",
                    onCTA: {
                        presentedCapability = nil
                        if !store.isActive {
                            Task { await store.purchase() }
                        }
                    },
                    onDismiss: { presentedCapability = nil }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .animation(MobileTheme.Animation.gentle, value: store.isActive)
        .animation(MobileTheme.Animation.gentle, value: store.error)
    }
}

// MARK: - Hero

private struct CloudStorePosterHero: View {
    let store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            CloudBadge(size: .large)
                .padding(.top, MobileTheme.Spacing.lg)

            VStack(spacing: MobileTheme.Spacing.xs) {
                Text("OPENBURNBAR")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(2.4)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                Text("Cloud")
                    .font(MobileTheme.Typography.displayLarge)
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .accessibilityAddTraits(.isHeader)

                Text(tagline)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.xl)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    private var tagline: String {
        if store.isActive {
            return "Your quota, your conversations, your agents — synced across every device."
        }
        return "Hosted Codex refresh. Chat that follows you. Mac AI anywhere. From $4.99/mo."
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
                    .foregroundStyle(MobileTheme.ember)
                Spacer(minLength: 0)
                Text("MONTHLY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .background(
                        Capsule().fill(MobileTheme.Colors.surface)
                    )
                    .overlay(
                        Capsule().stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.7)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.product?.displayPrice ?? "$4.99")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("/ month")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Text("OpenBurnBar Cloud — Apple-verified, billed monthly. Cancel anytime in Settings → Apple ID.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
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
/// Warm Aurora glass surface — `.ultraThinMaterial` + the existing
/// `cardGradient` tint + ember-tinted hairline. Same chrome as every other
/// primary card in the iOS rebuild (PulseView, BurnView, etc.) so the Cloud
/// destination doesn't read as a different app.
private struct MercuryFoilCardModifier: ViewModifier {
    var cornerRadius: CGFloat = MobileTheme.Radius.lg

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(MobileTheme.cardGradient)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                MobileTheme.ember.opacity(0.30),
                                MobileTheme.Colors.border.opacity(0.50),
                                MobileTheme.blaze.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
    }
}

// MARK: - Capability Lineup
//
// Cards are now driven by `CloudCapability.all` so the headlines, metrics,
// and tap-to-detail scenarios live in one shared model alongside the
// `CapabilityDetailSheet`. Every card is tappable.

private struct CloudStoreCapabilityLineup: View {
    let isActive: Bool
    let onTap: (CloudCapability) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT'S INCLUDED")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(MobileTheme.ember)
                Spacer()
                Text("TAP TO SEE HOW")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                if isActive {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.ember)
                }
            }

            VStack(spacing: MobileTheme.Spacing.md) {
                ForEach(CloudCapability.all) { cap in
                    CloudStoreCapabilityCard(capability: cap, isActive: isActive) {
                        onTap(cap)
                    }
                }
            }
        }
    }
}

private struct CloudStoreCapabilityCard: View {
    let capability: CloudCapability
    let isActive: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            Haptics.light()
            onTap()
        }) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle().fill(MobileTheme.Colors.surface)
                    Circle().stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.9)
                    Image(systemName: capability.icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.ember)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(capability.headline)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(MobileTheme.ember)
                        }
                    }
                    Text(capability.metric)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(MobileTheme.ember)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text("SEE HOW IT FEELS")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .padding(.top, 4)
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(MobileTheme.Colors.surface)
                    if !reduceMotion {
                        MercuryShimmerOverlay()
                            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
                            .blendMode(.plusLighter)
                            .opacity(isPressed ? 0.55 : 0.30)
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
            .scaleEffect(isPressed ? 0.99 : 1.0)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(capability.headline)\(isActive ? ", active" : ""). \(capability.metric). Tap to see how it feels in practice.")
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) { isPressed = false }
                }
        )
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
                    .foregroundStyle(MobileTheme.ember)
                Spacer()
                Label(isActive ? "Included" : "Cloud only",
                      systemImage: isActive ? "checkmark.seal.fill" : "lock.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(isActive ? MobileTheme.ember : MobileTheme.Colors.textMuted)
            }

            Text("Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP for hosted clients; a local shim keeps decrypted snippets on-device for stdio.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
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
                        .foregroundStyle(MobileTheme.ember)
                }
                Link(destination: URL(string: "https://openburnbar.com/docs/remote-mcp-runbook")!) {
                    Label("Runbook", systemImage: "stethoscope")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.ember)
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
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MobileTheme.ember)
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
                    .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.62))
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
                    .foregroundStyle(client.isRevoked ? MobileTheme.Colors.textPrimary.opacity(0.42) : MobileTheme.ember)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(2)
                    Text("\(client.displayType) · \(client.modeSummary)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                    Text(client.scopeSummary)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.54))
                        .lineLimit(2)
                }

                Spacer(minLength: MobileTheme.Spacing.sm)

                if client.isRevoked {
                    Text("Revoked")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.48))
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
            .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.54))
        }
        .padding(MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(
                    client.isRevoked
                        ? AnyShapeStyle(MobileTheme.ember.opacity(0.45).opacity(0.35))
                        : AnyShapeStyle(MobileTheme.ember.opacity(0.28)),
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
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
                .padding(.horizontal, MobileTheme.Spacing.sm)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.6))
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
                .foregroundStyle(MobileTheme.ember)
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.top, MobileTheme.Spacing.lg)
                .padding(.bottom, MobileTheme.Spacing.sm)

            VStack(spacing: 0) {
                headerRow
                Divider().background(MobileTheme.ember.opacity(0.35))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    comparisonRow(row)
                    if index < rows.count - 1 {
                        Divider().background(MobileTheme.Colors.textPrimary.opacity(0.18))
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
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("FREE")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(width: 90, alignment: .trailing)
            Text("CLOUD")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.ember)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
    }

    private func comparisonRow(_ row: Row) -> some View {
        HStack {
            Text(row.label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.free)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Text(row.cloud)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
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
                .foregroundStyle(MobileTheme.ember)

            ForEach(bullets, id: \.1) { item in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                    Image(systemName: item.0)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.ember)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(item.2)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
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
                    .foregroundStyle(MobileTheme.ember)
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
                .foregroundStyle(MobileTheme.ember)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .tracking(1.0)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(row.1)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
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
            VStack(spacing: 2) {
                Text("OpenBurnBar Cloud")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(subtitleLine)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Haptics.medium()
                Task { await store.purchase() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    if store.isLoading {
                        MiningPickLoader(.inline, tint: .white)
                        Text("Processing…")
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                        Text("Become a Member — \(store.product?.displayPrice ?? "$4.99")/mo")
                    }
                }
            }
            .buttonStyle(.aurora(.primary, fullWidth: true))
            .disabled(store.isLoading || store.product == nil)

            HStack(spacing: MobileTheme.Spacing.md) {
                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    Text("Restore Purchases")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
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
                    MobileTheme.Colors.background.opacity(0.0),
                    MobileTheme.Colors.background.opacity(0.85),
                    MobileTheme.Colors.background.opacity(0.95)
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
                .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.5))
            Link("Terms", destination: CloudStoreLegalURLs.terms)
                .accessibilityIdentifier("cloudStore.termsOfUseLink")
        }
        .font(MobileTheme.Typography.tiny)
        .foregroundStyle(MobileTheme.ember)
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
    @State private var showBadgePicker = false

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            // Aurora burst membership card — vivid multi-stop gradient,
            // animated aurora ribbon, helmet sitting in a halo. Matches the
            // YouTab member row, just turned up for the destination.
            ZStack(alignment: .top) {
                memberAuroraBackdrop

                VStack(spacing: MobileTheme.Spacing.lg) {
                    Button {
                        Haptics.selection()
                        showBadgePicker = true
                    } label: {
                        CloudBadge(size: .large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change Cloud badge")
                    .padding(.top, MobileTheme.Spacing.xl)

                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text("PRO")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(1.8)
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [MobileTheme.ember, MobileTheme.amber],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                )
                            Text("OPENBURNBAR CLOUD")
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.heavy)
                                .tracking(2.0)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        Text("Member")
                            .font(MobileTheme.Typography.displayLarge)
                            .foregroundStyle(MobileTheme.primaryGradient)
                    }

                    statusRow
                    if let serial = memberSerialText {
                        serialChip(serial)
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .padding(.bottom, MobileTheme.Spacing.xl)
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                UnifiedDesignSystem.Colors.hermesAureate.opacity(0.95),
                                MobileTheme.amber.opacity(0.7),
                                MobileTheme.ember.opacity(0.6),
                                UnifiedDesignSystem.Colors.hermesAureate.opacity(0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
            )
            .shadow(color: MobileTheme.ember.opacity(0.40), radius: 28, y: 14)
            .shadow(color: MobileTheme.amber.opacity(0.22), radius: 40, y: 0)

            // "Change badge" link — quiet, unobtrusive. Tapping the badge
            // itself also opens the picker; this is the labelled affordance
            // for discoverability.
            Button {
                Haptics.selection()
                showBadgePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rosette")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Change badge")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(MobileTheme.ember)
            }
            .buttonStyle(.plain)

            actionRow
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .sheet(isPresented: $showBadgePicker) {
            NavigationStack {
                CloudBadgePicker()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var memberAuroraBackdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            MobileTheme.ember.opacity(0.48),
                            MobileTheme.amber.opacity(0.38),
                            MobileTheme.blaze.opacity(0.30),
                            MobileTheme.whimsy.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // Aurora ribbon along the top
            LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.hermesAureate.opacity(0.35),
                    MobileTheme.amber.opacity(0.55),
                    MobileTheme.ember.opacity(0.40),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 80)
            .frame(maxHeight: .infinity, alignment: .top)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            // Halo behind the helmet
            RadialGradient(
                colors: [
                    MobileTheme.amber.opacity(0.55),
                    MobileTheme.ember.opacity(0.25),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 0,
                endRadius: 220
            )
            .blendMode(.plusLighter)
        }
    }

    /// Single warm status pill — renews relative for near-term, absolute
    /// month/year for far-horizon / sentinel dates so we never display
    /// "Renews in 73 years".
    private var statusRow: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.success)
            Text("Active")
                .font(MobileTheme.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("·")
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(renewLine)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            Capsule(style: .continuous)
                .fill(MobileTheme.Colors.success.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(MobileTheme.Colors.success.opacity(0.35), lineWidth: 0.5)
        )
    }

    /// Quiet subscription serial — small, monospaced, paired with a seal
    /// glyph. Reads as a real receipt line, not a costume.
    private func serialChip(_ serial: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(serial)
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    private var actionRow: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                Label("Manage", systemImage: "creditcard.fill")
            }
            .buttonStyle(.aurora(.primary, fullWidth: true))
            .accessibilityLabel("Manage subscription in App Store")

            Button {
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: 6) {
                    if store.isLoading {
                        MiningPickLoader(.inline, tint: MobileTheme.Colors.textPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Restore")
                }
            }
            .buttonStyle(.aurora(.secondary, fullWidth: true))
            .disabled(store.isLoading)
            .settingsAnchor(SettingsAnchor.cloudRestore)
        }
    }

    // MARK: - Derived strings

    private var renewLine: String {
        guard let expiration = store.expirationDate else { return "Renews monthly" }
        let interval = expiration.timeIntervalSinceNow
        if interval > 0, interval < 90 * 24 * 60 * 60 {
            return "Renews \(expiration.formatted(.relative(presentation: .named)))"
        }
        return "Renews monthly · through \(expiration.formatted(.dateTime.month(.abbreviated).year()))"
    }

    /// Real receipt-style serial drawn from the StoreKit transaction id.
    /// `nil` when we don't have a transaction yet (server-only restore,
    /// previews) — so we never invent a fake number.
    private var memberSerialText: String? {
        guard let tx = store.latestTransactionID else { return nil }
        let raw = String(tx)
        let suffix = String(raw.suffix(8))
        let padded = String(repeating: "0", count: max(0, 8 - suffix.count)) + suffix
        let grouped = padded.enumerated().map { idx, ch in
            (idx > 0 && idx % 4 == 0 ? "·" : "") + String(ch)
        }.joined()
        return "Receipt · \(grouped)"
    }

    private var accessibilitySummary: String {
        var parts: [String] = ["OpenBurnBar Cloud member"]
        parts.append(renewLine)
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
                        : MobileTheme.ember
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
