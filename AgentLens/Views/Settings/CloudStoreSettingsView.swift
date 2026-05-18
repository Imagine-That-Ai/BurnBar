import SwiftUI
import AppKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Cloud Store Settings View (macOS)
//
// Aurora-language parity with the iOS `CloudStoreView`. Warm
// `EmberSurfaceBackground`, glass cards with ember-tinted hairlines,
// primary-gradient capsule CTAs, SF-Rounded display, the user-selectable
// `CloudBadge` as the hero brand mark, an aurora-burst member card that
// matches the iOS YouTab certificate row exactly.
//
// macOS still routes purchase to the iOS App Store (universal SKU; macOS
// purchase flow not yet wired). Members who buy on iPhone see this pane
// in member state via the same Firestore entitlement doc.

struct CloudStoreSettingsView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var remoteMCPClients = MacRemoteMCPClientStore()
    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @State private var showBadgePicker = false

    var body: some View {
        ZStack {
            EmberSurfaceBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    hero
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .settingsAnchor(SettingsAnchor.cloudOverview)

                    if entitlement.isActive {
                        auroraMemberCard
                            .padding(.horizontal, 28)
                    } else {
                        planCard
                            .padding(.horizontal, 28)
                    }

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
        .sheet(isPresented: $showBadgePicker) {
            CloudBadgePicker()
        }
        .onAppear { entitlement.start() }
    }

    // MARK: - Aurora member card (active)
    //
    // Vivid ember/amber/blaze/whimsy burst, foil hairline border, drifting
    // aurora ribbon, large badge halo, PRO + "OPENBURNBAR CLOUD" tag,
    // "Member" in the primary gradient, status pill, Manage + Change badge
    // capsule buttons. Mirrors the iOS/Android member card 1:1.

    @ViewBuilder
    private var auroraMemberCard: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack(alignment: .top) {
            // Backdrop
            shape
                .fill(.ultraThinMaterial)
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.ember.opacity(0.50),
                            DesignSystem.Colors.amber.opacity(0.38),
                            DesignSystem.Colors.blaze.opacity(0.30),
                            DesignSystem.Colors.whimsy.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // Aurora ribbon along the top edge
            LinearGradient(
                colors: [
                    DesignSystem.Colors.hermesAureate.opacity(0.35),
                    DesignSystem.Colors.amber.opacity(0.55),
                    DesignSystem.Colors.ember.opacity(0.40),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 80)
            .frame(maxHeight: .infinity, alignment: .top)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            // Soft radial halo behind the badge
            RadialGradient(
                colors: [
                    DesignSystem.Colors.amber.opacity(0.55),
                    DesignSystem.Colors.ember.opacity(0.25),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: 240
            )
            .blendMode(.plusLighter)

            VStack(spacing: 14) {
                Button { showBadgePicker = true } label: {
                    CloudBadgeWithHalo(size: .large)
                }
                .buttonStyle(.plain)
                .help("Change Cloud badge")
                .padding(.top, 22)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text("PRO")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [DesignSystem.Colors.ember, DesignSystem.Colors.amber],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            )
                        Text("OPENBURNBAR CLOUD")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(2.0)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Text("Member")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }

                // Status pill
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Active")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("·").foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(entitlement.humanStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(DesignSystem.Colors.success.opacity(0.14))
                )
                .overlay(
                    Capsule().stroke(DesignSystem.Colors.success.opacity(0.45), lineWidth: 0.5)
                )

                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Manage", systemImage: "creditcard.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())

                    Button {
                        showBadgePicker = true
                    } label: {
                        Label("Change badge", systemImage: "rosette")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                }
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .clipShape(shape)
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.hermesAureate,
                        DesignSystem.Colors.amber,
                        DesignSystem.Colors.ember,
                        DesignSystem.Colors.hermesAureate
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.4
            )
        )
        .shadow(color: DesignSystem.Colors.ember.opacity(0.40), radius: 28, y: 14)
        .shadow(color: DesignSystem.Colors.amber.opacity(0.22), radius: 40, y: 0)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            Button {
                showBadgePicker = true
            } label: {
                CloudBadgeWithHalo(size: .large)
            }
            .buttonStyle(.plain)
            .help("Change Cloud badge")

            VStack(spacing: 6) {
                Text("OPENBURNBAR")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text("Cloud")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)

                Text("Hosted Codex refresh. Chat that follows you. Mac AI anywhere. From $4.99/mo.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Plan card

    private var planCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MEMBERSHIP")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2.4)
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Spacer()
                    Text("MONTHLY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .background(
                            Capsule().fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Capsule().stroke(DesignSystem.Colors.border, lineWidth: 0.6)
                        )
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$4.99")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    Text("/ month")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Text("Apple-verified, billed monthly via the App Store. Manage or cancel anytime in Settings → Apple ID.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let url = URL(string: "https://apps.apple.com/app/id6766366964") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Continue on iPhone", systemImage: "iphone")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(AuroraPrimaryButtonStyle())

                Link("Open pricing on openburnbar.com", destination: URL(string: "https://openburnbar.com/pricing")!)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.ember)
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
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.ember)
                Spacer()
            }

            VStack(spacing: 12) {
                capabilityRow(
                    icon: "cloud.fill",
                    tint: DesignSystem.Colors.ember,
                    title: "Hosted Codex quota",
                    detail: "Refresh Codex quota from any signed-in device. We run the runner; you get the dial."
                )
                capabilityRow(
                    icon: "arrow.triangle.2.circlepath",
                    tint: DesignSystem.Colors.amber,
                    title: "Conversation backup & resume",
                    detail: "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off."
                )
                capabilityRow(
                    icon: "text.alignleft",
                    tint: DesignSystem.Colors.blaze,
                    title: "Full session-log sync",
                    detail: "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device."
                )
                capabilityRow(
                    icon: "antenna.radiowaves.left.and.right",
                    tint: DesignSystem.Colors.whimsy,
                    title: "Hermes remote relay",
                    detail: "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end."
                )
            }
        }
    }

    private func capabilityRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        AuroraGlassCardMac(cornerRadius: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Remote MCP

    private var remoteMCPCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("REMOTE MCP", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2.4)
                        .foregroundStyle(DesignSystem.Colors.ember)
                    Spacer()
                    Label("Cloud only", systemImage: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Text("Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP uses the hosted endpoint; the local shim keeps decrypted snippets on-device.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                remoteMCPCommandRow(label: "Endpoint", value: "https://mcp.burnbar.ai/mcp")
                remoteMCPCommandRow(label: "Stdio shim", value: "openburnbar-mcp-remote mcp serve")
                remoteMCPCommandRow(label: "Doctor", value: "openburnbar mcp doctor")

                MacRemoteMCPConnectedClientsSection(store: remoteMCPClients)

                Link(destination: URL(string: "https://openburnbar.com/docs/remote-mcp")!) {
                    HStack(spacing: 6) {
                        Text("Open Remote MCP setup")
                        Image(systemName: "arrow.up.right.square.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.ember)
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
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Trust

    private var trustCard: some View {
        AuroraGlassCardMac {
            VStack(alignment: .leading, spacing: 12) {
                Text("THE TRUST MODEL")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.ember)

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
                    .foregroundStyle(DesignSystem.Colors.ember)
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
                .foregroundStyle(DesignSystem.Colors.amber)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Aurora glass card (macOS)
//
// Single chrome primitive used everywhere on this pane. UltraThinMaterial
// + warm `cardGradient` overlay + ember-tinted hairline. Replaces the old
// `MercuryFoilCard`.

private struct AuroraGlassCardMac<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DesignSystem.Colors.cardGradient)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.30),
                                DesignSystem.Colors.border.opacity(0.50),
                                DesignSystem.Colors.blaze.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
    }
}

// MARK: - Aurora primary button (macOS)
//
// Ember→amber gradient capsule with a thin amber hairline + ember-tinted
// drop shadow. Drop-in replacement for the iOS `.aurora(.primary)` style.

private struct AuroraPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.primaryGradient)
                    .opacity(configuration.isPressed ? 0.90 : 1.0)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.amber.opacity(0.55), lineWidth: 1.0)
            )
            .shadow(
                color: DesignSystem.Colors.ember.opacity(0.30),
                radius: configuration.isPressed ? 6 : 12,
                y: configuration.isPressed ? 2 : 6
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Quieter sibling — `.ultraThinMaterial` capsule with a thin border. For
/// "Change badge" / "Restore" affordances next to a primary CTA.
private struct AuroraSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.65), lineWidth: 0.6)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Remote MCP data + listener (preserved from previous design)
//
// The Firestore-backed model + listener for connected MCP clients. Chrome
// underneath has switched to Aurora glass; the rest of the structure is
// untouched.

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
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.clients.isEmpty && !store.isLoading {
                Text("No MCP clients are connected yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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
                Image(systemName: client.isRevoked ? "xmark.seal.fill" : "checkmark.seal.fill")
                    .foregroundStyle(client.isRevoked ? DesignSystem.Colors.textMuted : DesignSystem.Colors.success)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("\(client.displayType) · \(client.modeSummary)")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(client.scopeSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 8)

                if client.isRevoked {
                    Text("Revoked")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Button(action: onRevoke) {
                        Group {
                            if isRevoking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.error.opacity(0.88))
                    .disabled(isRevoking)
                    .accessibilityLabel("Revoke \(client.displayName)")
                }
            }

            Text(client.activitySummary)
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    client.isRevoked
                        ? AnyShapeStyle(DesignSystem.Colors.border.opacity(0.50))
                        : AnyShapeStyle(DesignSystem.Colors.ember.opacity(0.30)),
                    lineWidth: 0.6
                )
        )
    }
}

#Preview("Cloud Store Settings (macOS)") {
    CloudStoreSettingsView()
        .frame(width: 720, height: 600)
}
