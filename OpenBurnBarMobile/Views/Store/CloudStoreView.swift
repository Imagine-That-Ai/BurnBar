import SwiftUI
import StoreKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

private enum CloudStoreLegalURLs {
    static let privacy = URL(string: "https://burnbar.ai/legal/privacy-policy")!
    static let terms = URL(string: "https://burnbar.ai/legal/terms")!
}

private enum CloudSubscriptionDisclosure {
    static let title = "BurnBar Cloud, BurnBar Cloud Pro, and BurnBar Cloud Ultra"
    static let period = "Monthly or annual auto-renewable subscriptions"
    static let included = "BurnBar Cloud includes sync, encrypted history backup, cloud search, "
        + "Intelligence Brief fallback, remote relay, and Hosted Remote MCP. "
        + "BurnBar Cloud Pro adds Floo live control, supervised Agent Control, 500 hosted actions, and 50 relay GB. "
        + "BurnBar Cloud Ultra adds 10x agent memory (15 sources, 50,000 chunks, 250 MB) sealed on-device, "
        + "with the same hosted Agent Control and relay allowance as Pro."
    static let billing = "Billed by Apple. Auto-renews until canceled at least 24 hours before renewal. Manage or cancel in Settings -> Apple ID."
    static let reviewVisiblePlans = [
        "BurnBar Cloud Monthly - 1 month - $7.99 - 14-day intro free trial for new subscribers.",
        "BurnBar Cloud Annual - 1 year - $79 - 14-day intro free trial for new subscribers.",
        "BurnBar Cloud Pro Monthly - 1 month - $24.99 - no intro trial.",
        "BurnBar Cloud Pro Annual - 1 year - $249 - no intro trial.",
        "BurnBar Cloud Ultra Monthly - 1 month - $59.99 - no intro trial.",
        "BurnBar Cloud Ultra Annual - 1 year - $599 - no intro trial.",
        "Agent Control 100 Actions - consumable top-up - $4.99.",
        "Floo Relay 50 GB - consumable top-up - $4.99."
    ]
    static let reviewVisiblePlanSummary = "All App Store Connect subscriptions for this app are available here: \(reviewVisiblePlans.joined(separator: " "))"
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

    var onClose: (() -> Void)?

    @Environment(\.cloudSubscriptionStore) private var sharedStore
    @Environment(\.mobileAuthStore) private var authStore
    @Environment(\.dismiss) private var dismiss
    @State private var localStore = HostedQuotaSubscriptionStore()
    @State private var didLoadLocal = false
    @State private var presentedCapability: CloudCapability?
    @State private var showSignIn = false
    @State private var billingPeriod: CloudBillingPeriod = .monthly
    @StateObject private var remoteMCPClients = RemoteMCPClientStore()

    private var store: HostedQuotaSubscriptionStore {
        sharedStore ?? localStore
    }

    var body: some View {
        ZStack {
            MembershipBackdrop()

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

                        if store.isActivePro {
                            CloudStoreTopUpTile(store: store)
                                .padding(.horizontal, MobileTheme.Spacing.lg)
                                .settingsAnchor(SettingsAnchor.cloudPlan)
                                .staggeredEntrance(delay: 0.08)
                        } else {
                            CloudBillingPeriodToggle(period: $billingPeriod)
                                .padding(.horizontal, MobileTheme.Spacing.lg)
                                .settingsAnchor(SettingsAnchor.cloudPlan)
                                .staggeredEntrance(delay: 0.08)

                            CloudTierLineup(
                                store: store,
                                billingPeriod: billingPeriod,
                                showsCloudPlan: false
                            )
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .staggeredEntrance(delay: 0.10)

                            CloudTopUpStrip(store: store)
                                .padding(.horizontal, MobileTheme.Spacing.lg)
                                .settingsAnchor(SettingsAnchor.cloudPlan)
                                .staggeredEntrance(delay: 0.12)
                        }
                    } else {
                        CloudBillingPeriodToggle(period: $billingPeriod)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .settingsAnchor(SettingsAnchor.cloudPlan)
                            .staggeredEntrance(delay: 0.04)

                        CloudTierLineup(store: store, billingPeriod: billingPeriod)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .staggeredEntrance(delay: 0.06)

                        CloudTopUpStrip(store: store)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .settingsAnchor(SettingsAnchor.cloudPlan)
                            .staggeredEntrance(delay: 0.08)

                        CloudStoreActionBar(
                            store: store,
                            isSignedIn: authStore?.state.isSignedIn ?? true,
                            onSignInRequired: { showSignIn = true }
                        )
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .settingsAnchor(SettingsAnchor.cloudRestore)
                        .staggeredEntrance(delay: 0.10)
                    }

                    CloudStoreCapabilityLineup(isActive: store.isActive) { cap in
                        presentedCapability = cap
                    }
                    .padding(.horizontal, MobileTheme.Spacing.lg)
                    .staggeredEntrance(delay: 0.10)

                    CloudStoreRemoteMCPCard(isActive: store.isActive, clientStore: remoteMCPClients)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .accessibilityIdentifier("cloudStore.remoteMCP.card")
                        .staggeredEntrance(delay: 0.13)

                    CloudStoreComparisonCard()
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.17)

                    CloudStoreTrustCard()
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.21)

                    if !store.isActive {
                        CloudStoreSubscriptionDetails(
                            priceText: store.displayPrice(for: OpenBurnBarProductCatalog.subscriptions[0])
                        )
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .staggeredEntrance(delay: 0.23)
                    }

                    if store.isActive, let error = store.error {
                        CloudStoreErrorCard(message: error)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.top, MobileTheme.Spacing.md)
                .padding(.bottom, store.isActive ? MobileTheme.Spacing.xl : 140)
            }
            .settingsAnchor(SettingsAnchor.cloudRow)
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
                            .liquidGlassInteractive(in: .circle)
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
        .sheet(isPresented: $showSignIn) {
            if let authStore {
                SignInScene(authStore: authStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            NotificationCenter.default.post(
                name: .cloudStoreChromeVisibilityChanged,
                object: true
            )
        }
        .onDisappear {
            NotificationCenter.default.post(
                name: .cloudStoreChromeVisibilityChanged,
                object: false
            )
        }
        .onChange(of: authStore?.state.isSignedIn ?? false) { _, isSignedIn in
            if isSignedIn {
                showSignIn = false
            }
        }
        .sheet(item: $presentedCapability) { cap in
            NavigationStack {
                CapabilityDetailSheet(
                    capability: cap,
                    ctaLabel: store.isActive ? "Manage Cloud" : "View Cloud Plan",
                    onCTA: {
                        presentedCapability = nil
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

extension Notification.Name {
    static let cloudStoreChromeVisibilityChanged = Notification.Name("CloudStoreChromeVisibilityChanged")
}

// MARK: - Hero

private struct CloudStorePosterHero: View {
    let store: HostedQuotaSubscriptionStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    /// The poster wears the viewer's tier palette — warm ember until they
    /// hold a power tier (`.none` shares the warm Cloud stops).
    private var posterTier: CloudTier { store.cloudTier }

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(posterTier.holoGradient)
                    .frame(width: 110, height: 110)
                    .blur(radius: 30)
                    .opacity(breathe ? 0.50 : 0.26)
                    .scaleEffect(breathe ? 1.08 : 0.92)
                CloudBadge(size: .large)
                    .offset(y: breathe ? -2.5 : 2.5)
            }
            .padding(.top, MobileTheme.Spacing.lg)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 4.6).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }

            VStack(spacing: MobileTheme.Spacing.xs) {
                Text("OPENBURNBAR")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(4.0)
                    .foregroundStyle(ProTheme.Membership.foilLeaf)

                Text("Cloud")
                    .font(ProTheme.Typography.displaySerif)
                    .foregroundStyle(ProTheme.Membership.engraving)
                    .overlay(
                        ProTheme.Membership.foilEdge
                            .mask(
                                Text("Cloud").font(ProTheme.Typography.displaySerif)
                            )
                            .opacity(0.55)
                    )
                    .accessibilityAddTraits(.isHeader)

                foilHairline
                    .padding(.horizontal, MobileTheme.Spacing.xxl)
                    .padding(.vertical, MobileTheme.Spacing.xs)

                Text(tagline)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(ProTheme.Membership.engravingSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MobileTheme.Spacing.xl)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    private var foilHairline: some View {
        ProTheme.Membership.foilEdge
            .frame(height: 1)
            .mask(
                LinearGradient(
                    colors: [.clear, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .accessibilityHidden(true)
    }

    private var tagline: String {
        if store.isActive {
            return "Your quota, your conversations, your agents — synced across every device."
        }
        return "Sync, search, and connect your agent memory across devices. Cloud starts at $7.99/mo."
    }
}

// MARK: - Member Top-Up Tile (active Pro state)
//
// The free-state plan tile is now `CloudTierLineup` + `CloudTopUpStrip` in
// CloudTierComponents.swift. This tile remains for active Cloud Pro members
// who can buy consumable top-ups against the current month.

private struct CloudStoreTopUpTile: View {
    @Bindable var store: HostedQuotaSubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("CLOUD PRO TOP-UPS")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(ProTheme.Membership.foilLeaf)

            HStack(spacing: MobileTheme.Spacing.md) {
                ForEach(OpenBurnBarProductCatalog.topUps) { topUp in
                    CloudTopUpChip(
                        catalogProduct: topUp,
                        priceText: store.displayPrice(for: topUp),
                        isDisabled: false,
                        isPurchasing: store.isPurchasing
                    ) {
                        Haptics.medium()
                        Task { await store.purchase(productID: topUp.id) }
                    }
                }
            }

            if let credit = store.lastTopUpCredit, credit.credited {
                Text("Top-up credited: \(credit.units) units for \(credit.monthKey).")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Membership.foilLeaf)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membershipCard()
        .accessibilityIdentifier("cloudStore.topUps")
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
        // Delegates to the adaptive membership chrome so every supporting
        // section on the Cloud destination shares the obsidian-foil (dark) /
        // gold-leaf letterpress (light) identity instead of the warm Aurora
        // card. Shimmer is disabled here to keep dense info cards calm.
        content.membershipCard(
            cornerRadius: cornerRadius,
            enableShimmer: false,
            strokeWidth: 0.8
        )
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
                    .foregroundStyle(ProTheme.Membership.foilLeaf)
                Spacer()
                Text("TAP TO SEE HOW")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .foregroundStyle(ProTheme.Membership.engravingMuted)
                if isActive {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(ProTheme.Membership.foilLeaf)
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
        Button {
            Haptics.light()
            onTap()
        } label: {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle().fill(ProTheme.Membership.surfaceElevated)
                    Circle().stroke(ProTheme.Membership.foilEdge, lineWidth: 0.9)
                    Image(capability.art)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .padding(7)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(capability.headline)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(ProTheme.Membership.engraving)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ProTheme.Membership.foilLeaf)
                        }
                    }
                    Text(capability.metric)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(ProTheme.Membership.foilLeaf)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text("SEE HOW IT FEELS")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(ProTheme.Membership.engravingMuted)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ProTheme.Membership.engravingMuted)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ProTheme.Membership.engravingMuted)
                    .padding(.top, 4)
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(ProTheme.Membership.surface)
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
                    .stroke(ProTheme.Membership.foilEdge, lineWidth: 0.7)
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

    private nonisolated(unsafe) var listener: ListenerRegistration?
    private nonisolated(unsafe) var authHandle: AuthStateDidChangeListenerHandle?

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

    private let endpoint = "https://mcp.burnbar.ai/mcp"
    private let stdioCommand = "openburnbar-mcp-remote mcp serve"
    private let doctorCommand = "openburnbar mcp doctor"

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                ZStack {
                    Circle().fill(ProTheme.Membership.surfaceElevated)
                    Circle().stroke(ProTheme.Membership.foilEdge, lineWidth: 0.9)
                    Image("CloudCapRemoteMCP")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .padding(6)
                }
                .frame(width: 40, height: 40)
                Text("REMOTE MCP")
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
                Link(destination: URL(string: "https://burnbar.ai/product")!) {
                    Label("Setup", systemImage: "arrow.up.right.square.fill")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.ember)
                }
                Link(destination: URL(string: "https://burnbar.ai/security")!) {
                    Label("Runbook", systemImage: "stethoscope")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.ember)
                }
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MercuryFoilCardModifier())
        .accessibilityElement(children: .contain)
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
                    .accessibilityIdentifier("cloudStore.remoteMCP.connectedClients.title")
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MobileTheme.ember)
                        .accessibilityIdentifier("cloudStore.remoteMCP.connectedClients.loading")
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloudStore.remoteMCP.connectedClients.error")
            } else if store.clients.isEmpty && !store.isLoading {
                Text("No MCP clients are connected yet.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloudStore.remoteMCP.connectedClients.empty")
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
                .accessibilityIdentifier("cloudStore.remoteMCP.confirmRevoke")
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
                        .accessibilityIdentifier("cloudStore.remoteMCP.client.\(client.id).displayName")
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
                    .accessibilityIdentifier("cloudStore.remoteMCP.client.\(client.id).revoke")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloudStore.remoteMCP.client.\(client.id).row")
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
        Row(label: "Quota refresh", free: "Local-only", cloud: "On-demand, anywhere"),
        Row(label: "Chat backup", free: "Metadata only", cloud: "Full content"),
        Row(label: "Session logs", free: "Manifest only", cloud: "Search metadata"),
        Row(label: "Hermes Remote Relay", free: "Local network", cloud: "Anywhere"),
        Row(label: "Remote MCP", free: "Local helper", cloud: "Hosted endpoint")
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
    private let bullets: [(art: String, title: String, detail: String)] = [
        ("CloudSealApple", "Apple-verified", "Every transaction JWS is checked against Apple's root certificates server-side."),
        ("CloudSealUID", "UID-bound", "Each purchase is bound to your Firebase UID via a signed appAccountToken."),
        ("CloudSealCancel", "Cancel anytime", "Managed by Apple in Settings → Apple ID. We never store payment details.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("THE TRUST MODEL")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(MobileTheme.ember)

            ForEach(bullets, id: \.title) { item in
                HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                    Image(item.art)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(item.detail)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                Link(destination: URL(string: "https://burnbar.ai/pricing")!) {
                    HStack(spacing: 6) {
                        Text("Read the BurnBar Cloud pricing details")
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
            ("Available subscriptions", CloudSubscriptionDisclosure.reviewVisiblePlanSummary),
            ("Billing", CloudSubscriptionDisclosure.billing)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("SUBSCRIPTION DETAILS")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.bold)
                .tracking(1.2)
                .foregroundStyle(MobileTheme.ember)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .tracking(0.4)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(row.1)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CloudStoreLegalLinks(alignment: .leading, verboseLabels: true)
                    .padding(.top, MobileTheme.Spacing.xs)
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
    let isSignedIn: Bool
    let onSignInRequired: () -> Void

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Button {
                Haptics.medium()
                Task { await store.purchase() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    if store.isPurchasing {
                        MiningPickLoader(.inline, tint: MobileTheme.Colors.textPrimary)
                    } else {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 16, weight: .bold))
                    }
                    Text(primaryButtonTitle)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.aurora(.primary, fullWidth: true))
            .disabled(store.isPurchasing)
            .accessibilityIdentifier("cloudStore.subscribe")
            .accessibilityLabel(primaryButtonTitle)

            if let error = store.error {
                CloudStoreErrorCard(message: error)
                    .accessibilityIdentifier("cloudStore.purchaseError")
            }

            Button {
                guard isSignedIn else {
                    onSignInRequired()
                    return
                }
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: "arrow.clockwise")
                    Text("Restore Purchases")
                }
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
            }
            .buttonStyle(.aurora(.secondary, fullWidth: true))
            .disabled(store.isLoading || store.isPurchasing)
            .accessibilityIdentifier("cloudStore.restore")

            CloudStoreLegalLinks(alignment: .center, verboseLabels: true)
        }
        .padding(MobileTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(ProTheme.Membership.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(ProTheme.Membership.foilEdge, lineWidth: 1)
        )
        .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.18), radius: 18, y: 10)
    }

    private var primaryButtonTitle: String {
        if store.isPurchasing {
            return "Purchasing..."
        }
        guard let product = store.product else {
            return "Subscribe with App Store"
        }
        return "Subscribe for \(product.displayPrice) / month"
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
    var verboseLabels = false

    var body: some View {
        HStack(spacing: 8) {
            Link(verboseLabels ? "Privacy Policy" : "Privacy", destination: CloudStoreLegalURLs.privacy)
                .accessibilityIdentifier("cloudStore.privacyPolicyLink")
            Text("·")
                .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.5))
            Link(verboseLabels ? "Terms of Use (EULA)" : "Terms", destination: CloudStoreLegalURLs.terms)
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
    @Environment(\.openURL) private var openURL
    @State private var showBadgePicker = false
    @State private var badgeBreathe = false

    /// The member's holographic tier for accents — and for the chip label,
    /// which never overstates: base Cloud members wear CLOUD, not PRO.
    /// Delegates to the store's canonical §4.2 tier resolution.
    private var memberTier: CloudTier { store.cloudTier }

    private var memberTierLabel: String {
        switch memberTier {
        case .ultra:        return "ULTRA"
        case .pro:          return "PRO"
        case .none, .cloud: return "CLOUD"
        }
    }

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
                        // The badge floats on a breathing tier-colored halo —
                        // the certificate's living centerpiece.
                        ZStack {
                            Circle()
                                .fill(memberTier.holoGradient)
                                .frame(width: 96, height: 96)
                                .blur(radius: 26)
                                .opacity(badgeBreathe ? 0.55 : 0.30)
                                .scaleEffect(badgeBreathe ? 1.08 : 0.92)
                            CloudBadge(size: .large)
                                .offset(y: badgeBreathe ? -2 : 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change Cloud badge")
                    .padding(.top, MobileTheme.Spacing.xl)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                            badgeBreathe = true
                        }
                    }

                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text(memberTierLabel)
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .tracking(1.8)
                                .foregroundStyle(ProTheme.Membership.letterpress)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(memberTier.holoGradient))
                                .overlay(
                                    HoloSheenSweep(tint: .white, period: 6.0, bandOpacity: 0.5)
                                        .clipShape(Capsule(style: .continuous))
                                )
                            Text("OPENBURNBAR CLOUD")
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.heavy)
                                .tracking(2.4)
                                .foregroundStyle(ProTheme.Membership.foilLeaf)
                        }
                        Text("Member")
                            .font(ProTheme.Typography.displaySerif)
                            .foregroundStyle(ProTheme.Membership.engraving)
                            .overlay(
                                ProTheme.Membership.foilEdge
                                    .mask(Text("Member").font(ProTheme.Typography.displaySerif))
                                    .opacity(0.5)
                            )
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
                    .stroke(ProTheme.Membership.foilEdge, lineWidth: 1.4)
            )
            .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.32), radius: 28, y: 14)
            .shadow(color: Color.black.opacity(0.22), radius: 18, y: 8)

            // "Change badge" link — quiet, unobtrusive. Tapping the badge
            // itself also opens the picker; this is the labelled affordance
            // for discoverability.
            Button {
                Haptics.selection()
                showBadgePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rosette")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Change badge")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(ProTheme.Membership.foilLeaf)
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
                .fill(ProTheme.Membership.surface)
            // Foil-leaf wash for depth — gold in light, platinum in dark.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ProTheme.Membership.foilLeaf.opacity(0.22),
                            ProTheme.Membership.surfaceElevated.opacity(0.0),
                            ProTheme.Membership.foilHighlight.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // The member's tier crest as a faint iridescent ghost behind the
            // certificate header — replaces the old hard-edged foil band.
            HolographicCrestAura(
                crestImageName: memberTier.crestAssetName,
                gradient: memberTier.holoGradient,
                intensity: .card
            )
            .mask(
                LinearGradient(
                    colors: [.white, .white.opacity(0.0)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.72)
                )
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            // Living dust + a slow glint across the whole certificate.
            HoloSparksOverlay(colors: memberTier.holoStops)
            HoloSheenSweep(tint: .white, period: 7.5, bandOpacity: 0.16)
            // Halo behind the crest.
            RadialGradient(
                colors: [
                    ProTheme.Membership.foilHighlight.opacity(0.40),
                    UnifiedDesignSystem.Colors.ember.opacity(0.18),
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(serial)
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    private var actionRow: some View {
        // Both actions wear the membership vocabulary — the foil CTA and a
        // quiet engraved secondary — instead of the utilitarian Aurora
        // buttons, so the certificate stays one coherent object.
        HStack(spacing: MobileTheme.Spacing.md) {
            FoilCTAButton(title: "Manage", icon: "creditcard.fill") {
                openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
            .accessibilityLabel("Manage subscription in App Store")

            Button {
                Task { await store.restorePurchases() }
            } label: {
                HStack(spacing: 6) {
                    if store.isLoading {
                        MiningPickLoader(.inline, tint: ProTheme.Membership.engraving)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text("Restore")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(ProTheme.Membership.engraving)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MobileTheme.Spacing.md + 2)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(ProTheme.Membership.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(ProTheme.Membership.foilEdge, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .accessibilityIdentifier("cloudStore.member.restore")
            .accessibilityLabel("Restore purchases")
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
