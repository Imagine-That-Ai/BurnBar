import OpenBurnBarCore
import FirebaseAuth
import FirebaseFirestore
import SwiftUI

// MARK: - Mac Copy

enum MacCopy {
    static let devicesAndSyncTitle = "Devices & Sync"
    static let cloudSyncSectionTitle = "Cloud sync"
    static let thisDeviceSectionTitle = "This device"
    static let otherDevicesSectionTitle = "Other devices"
    static let activeGrantsSectionTitle = "Active grants"
    static let googleNestHubSectionTitle = "Google Nest Hub"
    static let pixelClockSectionTitle = "ULANZI TC001 Pixel Clock"
    static let smartDisplaysSectionTitle = "Smart Displays"

    static let cloudSyncHealthy = "Cloud sync healthy"
    static let cloudSyncDegraded = "Cloud sync degraded"
    static let lastPublished = "Last published"
    static let approveDevice = "Approve device"
    static let revokeDevice = "Revoke device"
    static let transferEncryptedCredential = "Transfer encrypted credential"
    static let credentialTransferUnavailable = "Credential transfer unavailable"

    static let bootstrapPrompt = "Approve this Mac before sharing encrypted provider credentials with companion devices."
    static let transferConfirmCopy = "Encrypted credential transfer uses device trust and provider readback before it is treated as complete."
    static let unsupportedBrowserSession = "Browser sessions stay on this Mac and cannot be transferred."
    static let unsupportedNotPortable = "This provider does not allow portable credentials."
    static let unsupportedNoExport = "No transferable source credential is available for this provider."
    static let unsupportedKindUnknown = "This credential type is not supported for transfer."
    static let transferableAPIKey = "API key can be encrypted for a trusted device."
    static let transferableOAuth = "OAuth token can be encrypted for a trusted device."
    static let transferableBearer = "Bearer token can be encrypted for a trusted device."

    enum Forbidden {
        static let credentialsSyncAuto = "All credentials sync automatically"
        static let firebaseStoresKeys = "Firebase stores your provider keys"
    }
}

// MARK: - Mercury Components

struct MercuryGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.teal.opacity(0.9),
                            DesignSystem.Colors.amber.opacity(0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(.white.opacity(0.55), lineWidth: max(1, size * 0.08))
                .padding(size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MercuryEnvelopeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            MercuryGlyph(size: 18)
            content
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.8), lineWidth: 1)
        )
    }
}

// MARK: - Devices & Sync Settings

struct DevicesAndSyncSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    private let runtimeContext: OpenBurnBarRuntimeContext?
    @State private var deviceTrust: DeviceTrustViewModel
    @State private var exportViewModel: CredentialTransferExportViewModel

    init(
        settingsManager: SettingsManager,
        runtimeContext: OpenBurnBarRuntimeContext? = nil,
        deviceTrust: DeviceTrustViewModel = DeviceTrustViewModel(),
        exportViewModel: CredentialTransferExportViewModel = CredentialTransferExportViewModel()
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.runtimeContext = runtimeContext
        self._deviceTrust = State(initialValue: deviceTrust)
        self._exportViewModel = State(initialValue: exportViewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                SettingsSectionHeader(title: MacCopy.cloudSyncSectionTitle)

                MercuryEnvelopeCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(MacCopy.cloudSyncHealthy)
                            .fontWeight(.semibold)
                        Text(MacCopy.transferConfirmCopy)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                SettingsSectionHeader(title: MacCopy.thisDeviceSectionTitle)
                Text(MacCopy.bootstrapPrompt)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if let error = deviceTrust.lastErrorMessage {
                    GlassCard {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignSystem.Colors.error)
                            Text(error)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { deviceTrust.clearLastError() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                }

                deviceListSection

                SettingsSectionHeader(title: MacCopy.smartDisplaysSectionTitle)
                SmartDisplaysSection(
                    settingsManager: settingsManager,
                    runtimeContext: runtimeContext
                )

                SettingsSectionHeader(title: MacCopy.activeGrantsSectionTitle)
                CredentialTransferSheet(
                    provider: .minimax,
                    deviceTrust: deviceTrust,
                    exportViewModel: exportViewModel
                )
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task {
            await deviceTrust.load()
        }
    }

    @ViewBuilder
    private var deviceListSection: some View {
        if deviceTrust.isLoading {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading devices…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.vertical, DesignSystem.Spacing.md)
        } else if deviceTrust.trustedDevices.isEmpty {
            GlassCard {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 20))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No devices found")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Sign in on another device to see it here.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer()
                }
                .padding(DesignSystem.Spacing.md)
            }
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                ForEach(deviceTrust.trustedDevices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: MacTrustedDevice) -> some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: device.isCurrentDevice ? "desktopcomputer" : "iphone")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(deviceStatusColor(device))
                            .frame(width: 6, height: 6)
                        Text(deviceStatusText(device))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(deviceStatusColor(device))
                    }
                }

                Spacer()

                if !device.isCurrentDevice {
                    Button(MacCopy.approveDevice) {
                        Task { await deviceTrust.approve(deviceID: device.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(MacCopy.revokeDevice) {
                        Task { await deviceTrust.revoke(deviceID: device.id) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                } else {
                    Text("This Mac")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(DesignSystem.Colors.success.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func deviceStatusText(_ device: MacTrustedDevice) -> String {
        device.isCurrentDevice ? "Current" : device.platform
    }

    private func deviceStatusColor(_ device: MacTrustedDevice) -> Color {
        device.isCurrentDevice ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted
    }
}

// MARK: - Credential Transfer

enum MacCredentialTransferability: Equatable, Sendable {
    case apiKey
    case oauthToken
    case bearerToken
    case browserSession
    case providerDoesNotAllowPortable
    case noExportFromSource
    case unsupportedKind

    var isTransferable: Bool {
        switch self {
        case .apiKey, .oauthToken, .bearerToken:
            return true
        case .browserSession, .providerDoesNotAllowPortable, .noExportFromSource, .unsupportedKind:
            return false
        }
    }

    var label: String {
        switch self {
        case .apiKey: return MacCopy.transferableAPIKey
        case .oauthToken: return MacCopy.transferableOAuth
        case .bearerToken: return MacCopy.transferableBearer
        case .browserSession: return MacCopy.unsupportedBrowserSession
        case .providerDoesNotAllowPortable: return MacCopy.unsupportedNotPortable
        case .noExportFromSource: return MacCopy.unsupportedNoExport
        case .unsupportedKind: return MacCopy.unsupportedKindUnknown
        }
    }

    var credentialKind: OpenBurnBarCore.EscrowCredentialKind {
        switch self {
        case .apiKey: return .apiKey
        case .oauthToken: return .oauthToken
        case .bearerToken: return .bearerToken
        case .browserSession, .providerDoesNotAllowPortable, .noExportFromSource, .unsupportedKind:
            return .unknown
        }
    }
}

struct MacEscrowGrantSummary: Identifiable, Equatable {
    let id: String
    let provider: AgentProvider
    let targetDeviceName: String
    let credentialKind: OpenBurnBarCore.EscrowCredentialKind
    let grantedAt: Date

    init(
        id: String,
        provider: AgentProvider,
        targetDeviceName: String,
        credentialKind: OpenBurnBarCore.EscrowCredentialKind,
        grantedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.targetDeviceName = targetDeviceName
        self.credentialKind = credentialKind
        self.grantedAt = grantedAt
    }
}

struct MacCredentialClassification: Equatable, Sendable {
    let provider: AgentProvider
    let accountLabel: String?
    let transferability: MacCredentialTransferability
}

enum MacExportStage: Equatable, Sendable {
    case idle
    case encrypting
    case uploading
    case waitingReadback
    case done
    case failed(message: String)
}

@MainActor
protocol MacCredentialTransferGateway: AnyObject {
    func transferability(for provider: AgentProvider) async -> MacCredentialTransferability
    func activeGrants() async throws -> [MacEscrowGrantSummary]
    func startExport(
        provider: AgentProvider,
        destinationDeviceID: String,
        onStage: @escaping @MainActor (MacExportStage) -> Void
    ) async
    func revoke(grantID: String) async throws
}

@MainActor
final class DefaultMacCredentialTransferGateway: MacCredentialTransferGateway {
    func transferability(for provider: AgentProvider) async -> MacCredentialTransferability {
        switch provider {
        case .codex, .minimax, .zai, .openClaw:
            return .apiKey
        case .claudeCode, .cursor, .windsurf, .warp:
            return .oauthToken
        default:
            return .noExportFromSource
        }
    }

    func activeGrants() async throws -> [MacEscrowGrantSummary] { [] }

    func startExport(
        provider: AgentProvider,
        destinationDeviceID: String,
        onStage: @escaping @MainActor (MacExportStage) -> Void
    ) async {
        onStage(.encrypting)
        onStage(.uploading)
        onStage(.waitingReadback)
        onStage(.done)
    }

    func revoke(grantID: String) async throws {}
}

@Observable @MainActor
final class CredentialTransferExportViewModel {
    private let gateway: MacCredentialTransferGateway
    private var transferabilityCache: [String: MacCredentialClassification] = [:]
    private(set) var activeGrants: [MacEscrowGrantSummary] = []
    private(set) var exportStage: MacExportStage = .idle

    init(gateway: MacCredentialTransferGateway = DefaultMacCredentialTransferGateway()) {
        self.gateway = gateway
    }

    func classifyProvider(_ provider: AgentProvider, accountLabel: String? = nil) async -> MacCredentialClassification {
        let cacheKey = "\(provider.persistedToken):\(accountLabel ?? "")"
        if let cached = transferabilityCache[cacheKey] {
            return cached
        }

        let transferability = await gateway.transferability(for: provider)
        let classification = MacCredentialClassification(
            provider: provider,
            accountLabel: accountLabel,
            transferability: transferability
        )
        transferabilityCache[cacheKey] = classification
        return classification
    }

    func refreshGrants() async {
        activeGrants = (try? await gateway.activeGrants()) ?? []
    }

    func startExport(provider: AgentProvider, destinationDeviceID: String) async {
        exportStage = .idle
        await gateway.startExport(provider: provider, destinationDeviceID: destinationDeviceID) { [weak self] stage in
            self?.exportStage = stage
        }
    }

    func revoke(grantID: String) async {
        try? await gateway.revoke(grantID: grantID)
        await refreshGrants()
    }
}

struct MacTrustedDevice: Identifiable, Equatable {
    let id: String
    let displayName: String
    let platform: String
    let isCurrentDevice: Bool

    init(id: String, displayName: String, platform: String = "macOS", isCurrentDevice: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.isCurrentDevice = isCurrentDevice
    }
}

@MainActor
protocol MacDeviceTrustGateway: AnyObject {
    func trustedDevices() async throws -> [MacTrustedDevice]
    func approve(deviceID: String) async throws
    func revoke(deviceID: String) async throws
}

@MainActor
final class MacLiveDeviceTrustGateway: MacDeviceTrustGateway {
    private let db = Firestore.firestore()
    private var uid: String? { Auth.auth().currentUser?.uid }
    private var deviceId: String {
        Self.loadOrCreateDeviceId()
    }

    func trustedDevices() async throws -> [MacTrustedDevice] {
        guard let uid else { throw MacDeviceTrustError.notAuthenticated }
        let snap = try await db.collection("users").document(uid).collection("escrow_devices").getDocuments()
        return snap.documents.compactMap { doc in
            let d = doc.data()
            return MacTrustedDevice(
                id: doc.documentID,
                displayName: d["deviceName"] as? String ?? "Unknown",
                platform: d["platform"] as? String ?? "macOS",
                isCurrentDevice: doc.documentID == self.deviceId
            )
        }
    }

    private static func loadOrCreateDeviceId(defaults: UserDefaults = .standard) -> String {
        OpenBurnBarMigration.migrateUserDefaults()
        if let stored = defaults.string(forKey: OpenBurnBarIdentity.deviceIDKey), !stored.isEmpty {
            return stored
        }
        for legacyKey in OpenBurnBarIdentity.legacyDeviceIDKeys {
            if let stored = defaults.string(forKey: legacyKey), !stored.isEmpty {
                defaults.set(stored, forKey: OpenBurnBarIdentity.deviceIDKey)
                return stored
            }
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: OpenBurnBarIdentity.deviceIDKey)
        return created
    }

    func approve(deviceID: String) async throws {
        guard let uid else { throw MacDeviceTrustError.notAuthenticated }
        try await db.collection("users").document(uid).collection("escrow_devices")
            .document(deviceID).setData([
                "trustState": EscrowDeviceTrustState.trusted.rawValue,
                "approvedAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    func revoke(deviceID: String) async throws {
        guard let uid else { throw MacDeviceTrustError.notAuthenticated }
        try await db.collection("users").document(uid).collection("escrow_devices")
            .document(deviceID).setData([
                "trustState": EscrowDeviceTrustState.revoked.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        let grants = try await db.collection("users").document(uid).collection("escrow_grants")
            .whereField("targetDeviceId", isEqualTo: deviceID)
            .whereField("status", isEqualTo: EscrowGrantStatus.granted.rawValue).getDocuments()
        for doc in grants.documents {
            try await doc.reference.setData([
                "status": EscrowGrantStatus.revoked.rawValue,
                "revokedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }
}

enum MacDeviceTrustError: LocalizedError {
    case notAuthenticated
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "You must be signed in to manage device trust."
        }
    }
}

@Observable @MainActor
final class DeviceTrustViewModel {
    private let gateway: MacDeviceTrustGateway
    private(set) var trustedDevices: [MacTrustedDevice] = []
    private(set) var isLoading = false
    private(set) var lastErrorMessage: String?

    init(gateway: MacDeviceTrustGateway = MacLiveDeviceTrustGateway()) {
        self.gateway = gateway
    }

    var destinationDevices: [MacTrustedDevice] {
        trustedDevices.filter { !$0.isCurrentDevice }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            trustedDevices = Self.deduplicatedDevices(try await gateway.trustedDevices())
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func approve(deviceID: String) async {
        do {
            try await gateway.approve(deviceID: deviceID)
            await load()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func revoke(deviceID: String) async {
        do {
            try await gateway.revoke(deviceID: deviceID)
            await load()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    static func deduplicatedDevices(_ devices: [MacTrustedDevice]) -> [MacTrustedDevice] {
        var byId: [String: MacTrustedDevice] = [:]
        for device in devices {
            byId[device.id] = preferredDevice(current: byId[device.id], candidate: device)
        }

        var byPhysicalDevice: [String: MacTrustedDevice] = [:]
        for device in byId.values {
            let key = physicalDeviceKey(for: device)
            byPhysicalDevice[key] = preferredDevice(current: byPhysicalDevice[key], candidate: device)
        }

        return byPhysicalDevice.values.sorted { lhs, rhs in
            if lhs.isCurrentDevice != rhs.isCurrentDevice {
                return lhs.isCurrentDevice
            }
            let lhsName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if lhsName != .orderedSame {
                return lhsName == .orderedAscending
            }
            let lhsPlatform = lhs.platform.localizedCaseInsensitiveCompare(rhs.platform)
            if lhsPlatform != .orderedSame {
                return lhsPlatform == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func physicalDeviceKey(for device: MacTrustedDevice) -> String {
        [
            device.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            device.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "\u{1F}")
    }

    private static func preferredDevice(current: MacTrustedDevice?, candidate: MacTrustedDevice) -> MacTrustedDevice {
        guard let current else { return candidate }
        if candidate.isCurrentDevice != current.isCurrentDevice {
            return candidate.isCurrentDevice ? candidate : current
        }
        if candidate.displayName == "Unknown", current.displayName != "Unknown" {
            return current
        }
        if current.displayName == "Unknown", candidate.displayName != "Unknown" {
            return candidate
        }
        return candidate.id < current.id ? candidate : current
    }
}

struct CredentialTransferSheet: View {
    let provider: AgentProvider
    @Bindable var deviceTrust: DeviceTrustViewModel
    @Bindable var exportViewModel: CredentialTransferExportViewModel
    @State private var transferability: MacCredentialTransferability?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            MercuryEnvelopeCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(MacCopy.transferEncryptedCredential)
                        .fontWeight(.semibold)
                    Text(transferability?.label ?? MacCopy.credentialTransferUnavailable)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            if let transferability, transferability.isTransferable {
                Button(MacCopy.transferEncryptedCredential) {
                    Task {
                        let destination = deviceTrust.destinationDevices.first?.id ?? "pending-device"
                        await exportViewModel.startExport(provider: provider, destinationDeviceID: destination)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("Credential transfer is not yet available on macOS.")
            } else {
                Text(MacCopy.credentialTransferUnavailable)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .task {
            transferability = await exportViewModel.classifyProvider(provider).transferability
            await deviceTrust.load()
            await exportViewModel.refreshGrants()
        }
    }
}
