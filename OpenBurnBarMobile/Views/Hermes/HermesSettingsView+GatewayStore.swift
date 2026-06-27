import OSLog
import SwiftUI
import UIKit
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

// Hermes gateway settings store (pairing/connection state machine).
// Extracted from HermesSettingsView.swift (god-file decomposition) — same module, verbatim.

struct HermesGatewayApprovalDetailKey: Hashable, Sendable {
    let clientId: String
    let actionId: String
}

enum HermesGatewayApprovalDetailIndex {
    static func keyedByApprovalTarget(from messages: [HermesGatewayMessageRecord]) -> [HermesGatewayApprovalDetailKey: String] {
        messages.reduce(into: [:]) { acc, record in
            if record.resolvedKind == "approval",
               let actionId = record.resolvedActionId,
               let detail = record.resolvedText,
               !record.clientId.isEmpty,
               !actionId.isEmpty,
               !detail.isEmpty {
                acc[HermesGatewayApprovalDetailKey(clientId: record.clientId, actionId: actionId)] = detail
            }
        }
    }
}

@Observable
@MainActor
final class HermesGatewaySettingsStore {
    private let repository: any HermesGatewayRepository
    @ObservationIgnored private let defaults: UserDefaults
    private static let selectedClientDefaultsKey = "hermesGateway.selectedClientId"

    private(set) var clients: [HermesGatewayClientRecord] = []
    private(set) var selectedClientId: String?
    private(set) var isLoading = false
    private(set) var isApproving = false
    private(set) var isSendingTest = false
    private(set) var isSendingGatewayMessage = false
    private(set) var isSwitchingModel = false
    private(set) var revokingClientId: String?
    private(set) var isPruningStaleClients = false
    private(set) var noticeText: String?
    private(set) var noticeStyle: HermesGatewayNoticeStyle = .info
    private(set) var pendingTestEvent: HermesGatewayQueuedEvent?
    private(set) var pendingModelSwitchEvent: HermesGatewayQueuedEvent?
    private(set) var latestReply: HermesGatewayMessageRecord?
    private(set) var approvals: [HermesGatewayApprovalRecord] = []
    /// MP-6: end-to-end-encrypted approval detail text, keyed by the approval's
    /// client/action pair so two gateway clients cannot collide on the same
    /// sealed action id. Populated from opened gateway messages whose
    /// `kind == "approval"`; the /approvals control-plane record itself never
    /// carries this text.
    private(set) var sealedApprovalDetails: [HermesGatewayApprovalDetailKey: String] = [:]
    private(set) var respondingApprovalId: String?
    private(set) var settingOversightClientId: String?
    private(set) var statusNow = Date()

    @ObservationIgnored private var clientListener: ListenerRegistration?
    @ObservationIgnored private var messageListener: ListenerRegistration?
    @ObservationIgnored private var approvalListener: ListenerRegistration?
    @ObservationIgnored private var statusClockTask: Task<Void, Never>?
    @ObservationIgnored private var listenedUID: String?
    @ObservationIgnored private let agentKeyPinStore = HermesGatewayAgentKeyPinStore()
    @ObservationIgnored private var lastNotifiedMessageID: String?
    @ObservationIgnored private var pendingEventSentAt: Date?
    @ObservationIgnored private var messageListenerStartedAt: Date?
    @ObservationIgnored private let gatewayThreadID = HermesGatewayMessageResolver.defaultThreadID
    @ObservationIgnored private var openedGatewayAttachments: [String: HermesAttachment] = [:]
    @ObservationIgnored private var failedGatewayAttachmentIDs = Set<String>()
    private static let maxGatewayAttachmentDownloadBytes =
        Int64(HermesAttachmentLimits.maxGenericBytes * 2 + 4096)

    init(repository: any HermesGatewayRepository = FunctionsRepository.shared, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        self.selectedClientId = defaults.string(forKey: Self.selectedClientDefaultsKey)
    }

    var activeClients: [HermesGatewayClientRecord] {
        clients.filter(\.isActive)
    }

    var displayClients: [HermesGatewayClientRecord] {
        Self.deduplicateGatewayClients(activeClients, relativeTo: statusNow)
    }

    var hiddenDuplicateClients: [HermesGatewayClientRecord] {
        let visibleIDs = Set(displayClients.map(\.id))
        return activeClients.filter { !visibleIDs.contains($0.id) }
    }

    var hiddenDuplicateClientCount: Int {
        hiddenDuplicateClients.count
    }

    func sealedApprovalDetail(for approval: HermesGatewayApprovalRecord) -> String? {
        sealedApprovalDetails[HermesGatewayApprovalDetailKey(clientId: approval.clientId, actionId: approval.actionId)]
    }

    var connectedClientCountText: String {
        "\(displayClients.count)"
    }

    var onlineClients: [HermesGatewayClientRecord] {
        displayClients.filter { $0.isOnline(relativeTo: statusNow) }
    }

    /// Oversight gates still waiting for a decision and not past their
    /// server-stamped expiry, newest first.
    var waitingApprovals: [HermesGatewayApprovalRecord] {
        approvals
            .filter { $0.isActionable(relativeTo: statusNow) }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    var selectedClient: HermesGatewayClientRecord? {
        if let selectedClientId,
           let client = displayClients.first(where: { $0.id == selectedClientId }) {
            return client
        }
        return onlineClients.first ?? displayClients.first
    }

    var selectedTargetClientId: String? {
        selectedClient?.id
    }

    var runtimeModelOptions: [HermesRuntimeModelOption] {
        var seen = Set<String>()
        var options: [HermesRuntimeModelOption] = []
        var seenClients = Set<String>()
        let clientsByPriority = ([selectedClient].compactMap(\.self) + onlineClients + displayClients)
            .reduce(into: [HermesGatewayClientRecord]()) { result, client in
                guard !seenClients.contains(client.id) else { return }
                seenClients.insert(client.id)
                result.append(client)
            }
        for client in clientsByPriority {
            for option in client.runtimeModelOptions {
                let key = option.modelId.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                options.append(option.hermesRuntimeOption)
            }
            if let modelId = nonEmpty(client.runtimeModelId) {
                let key = modelId.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    options.append(
                        HermesRuntimeModelOption(
                            providerID: nonEmpty(client.runtimeProviderId) ?? "hermes",
                            providerName: nonEmpty(client.runtimeProviderId) ?? "Hermes",
                            modelID: modelId,
                            displayName: modelId,
                            sourceKind: "burnbar-cloud-gateway",
                            routeEligible: true
                        )
                    )
                }
            }
        }
        return options
    }

    var runtimeModelId: String? {
        selectedClient.flatMap { nonEmpty($0.runtimeModelId) }
            ?? onlineClients.compactMap { nonEmpty($0.runtimeModelId) }.first
            ?? displayClients.compactMap { nonEmpty($0.runtimeModelId) }.first
    }

    private static func deduplicateGatewayClients(
        _ clients: [HermesGatewayClientRecord],
        relativeTo now: Date
    ) -> [HermesGatewayClientRecord] {
        var bestByDevice: [String: HermesGatewayClientRecord] = [:]
        for client in clients where client.isActive {
            let key = gatewayClientDuplicateKey(client)
            if let existing = bestByDevice[key] {
                if shouldPreferGatewayClient(client, over: existing, relativeTo: now) {
                    bestByDevice[key] = client
                }
            } else {
                bestByDevice[key] = client
            }
        }
        return bestByDevice.values.sorted {
            shouldPreferGatewayClient($0, over: $1, relativeTo: now)
        }
    }

    private static func gatewayClientDuplicateKey(_ client: HermesGatewayClientRecord) -> String {
        // The gateway can accumulate multiple active grants when the same
        // device is re-paired during local testing. Use gateway-owned identity
        // material first: the phone relay key identifies this phone and is
        // shared across multiple gateway clients, so it must never collapse
        // distinct clients or steer routing to the wrong target. Older records
        // without gateway key material fall back to a normalized display name
        // plus home destination.
        let homeDestination = gatewayClientDestinationKey(client.homeDestinationId)
        if normalizedNonEmpty(client.phoneRelayPublicKey, lowercase: false) != nil,
           let agentRelayKey = normalizedNonEmpty(client.relayPublicKey, lowercase: false) {
            return "agent|\(agentRelayKey)|\(homeDestination)"
        }
        if normalizedNonEmpty(client.phoneRelayPublicKey, lowercase: false) != nil {
            return "client|\(client.id)|\(homeDestination)"
        }
        let displayName = gatewayClientDisplayNameKey(client.displayName)
        if displayName != "unknown-device" {
            return "name|\(displayName)|\(homeDestination)"
        }
        if let agentRelayKey = normalizedNonEmpty(client.relayPublicKey, lowercase: false) {
            return "agent|\(agentRelayKey)|\(homeDestination)"
        }
        return "name|\(displayName)|\(homeDestination)"
    }

    private static func gatewayClientDisplayNameKey(_ value: String?) -> String {
        guard let value = normalizedNonEmpty(value, lowercase: true) else {
            return "unknown-device"
        }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func gatewayClientDestinationKey(_ value: String?) -> String {
        let destination = normalizedNonEmpty(value, lowercase: true) ?? "burnbar:home"
        switch destination {
        case "home", "burnbar/home", "burnbar:home":
            return "burnbar:home"
        default:
            return destination
        }
    }

    private static func shouldPreferGatewayClient(
        _ lhs: HermesGatewayClientRecord,
        over rhs: HermesGatewayClientRecord,
        relativeTo now: Date
    ) -> Bool {
        let lhsOnline = lhs.isOnline(relativeTo: now)
        let rhsOnline = rhs.isOnline(relativeTo: now)
        if lhsOnline != rhsOnline { return lhsOnline }
        if lhs.canSealToAgent != rhs.canSealToAgent { return lhs.canSealToAgent }
        if lhs.canRatchetToAgent != rhs.canRatchetToAgent { return lhs.canRatchetToAgent }

        let lhsDate = gatewayClientSortDate(lhs)
        let rhsDate = gatewayClientSortDate(rhs)
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id > rhs.id
    }

    private static func gatewayClientSortDate(_ client: HermesGatewayClientRecord) -> Date {
        client.lastSeenDate
            ?? gatewayDate(from: client.updatedAt)
            ?? gatewayDate(from: client.createdAt)
            ?? .distantPast
    }

    private static func gatewayDate(from raw: String?) -> Date? {
        guard let raw = normalizedNonEmpty(raw, lowercase: false) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func normalizedNonEmpty(_ value: String?, lowercase: Bool) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return lowercase ? trimmed.lowercased() : trimmed
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func gatewayE2EERequiredMessage(for client: HermesGatewayClientRecord) -> String {
        "Update OpenBurnBar on \(client.displayName), then reconnect Hermes so private messages can be read on both sides."
    }

    private static func gatewayRelayKeyChangedMessage(for client: HermesGatewayClientRecord) -> String {
        "\(client.displayName)'s connection looks different from when you set it up. Nothing was sent, to keep things safe. Reconnect Hermes on \(client.displayName) to restore private replies."
    }

    /// True when the agent pubkey this client now advertises differs from the one
    /// pinned at first pairing (possible MITM). Returns `false` when there is no
    /// pin yet (first trust), no usable key, or no signed-in uid — the seal path
    /// itself stays the authoritative fail-closed gate; this only drives the
    /// pre-flight notice and the badge.
    func agentRelayKeyChanged(for client: HermesGatewayClientRecord) -> Bool {
        guard
            client.canSealToAgent,
            let advertised = client.relayPublicKey,
            let uid = listenedUID, !uid.isEmpty,
            let pinned = agentKeyPinStore.pinnedKey(uid: uid, clientId: client.id)
        else {
            return false
        }
        return pinned != advertised.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clear the TOFU pin for a client so the next observed agent key is trusted
    /// afresh. Used on deliberate re-pair / revoke so re-pairing re-establishes
    /// trust instead of tripping the mismatch guard forever.
    private func clearAgentKeyPin(clientId: String) {
        guard let uid = listenedUID, !uid.isEmpty else { return }
        agentKeyPinStore.clearPin(uid: uid, clientId: clientId)
    }

    /// A short, human-comparable "safety code" for a paired client's private
    /// connection, so a user can compare it across their phone and Mac to confirm
    /// no one is intercepting the channel. Prefers the key this device has already
    /// trusted (the Keychain pin); before the first send pins a key it falls back
    /// to the key the connection currently advertises so the code is never blank
    /// on a freshly paired Mac. Returns `nil` only when there is genuinely no key
    /// to show.
    func agentSafetyCode(for client: HermesGatewayClientRecord) -> String? {
        guard let ratchetIdentityKeys = ratchetSafetyCodeKeys(for: client) else {
            return nil
        }
        if let uid = listenedUID, !uid.isEmpty,
           let pinned = agentKeyPinStore.pinnedSafetyCode(
            uid: uid,
            clientId: client.id,
            additionalPublicKeysBase64: ratchetIdentityKeys
           ) {
            return pinned
        }
        guard let advertised = client.relayPublicKey else { return nil }
        // MP-1: two-key code — the advertised agent key + this device's own relay key.
        guard let phoneKey = try? HermesGatewayRelayKeypair.loadOrCreate().relayPublicKeyBase64 else {
            return nil
        }
        return HermesGatewayAgentKeyPinStore.safetyCode(
            publicKeysBase64: [advertised, phoneKey] + ratchetIdentityKeys
        )
    }

    private func ratchetSafetyCodeKeys(for client: HermesGatewayClientRecord) -> [String]? {
        guard client.canRatchetToAgent else { return [] }
        guard
            let agentRatchetIdentity = nonEmpty(client.agentRatchetIdentityPublicKey),
            let localRatchetIdentity = try? HermesGatewayRatchetPrekeyStore.loadOrCreateBundle().identityPublicKeyBase64
        else {
            return nil
        }
        if let echoedPhoneIdentity = nonEmpty(client.phoneRatchetIdentityPublicKey),
           echoedPhoneIdentity != localRatchetIdentity.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        return [agentRatchetIdentity, localRatchetIdentity]
    }

    /// Explicit, user-confirmed re-pair for a client whose private connection now
    /// looks different from when it was first set up (a changed key — possible
    /// interception — or a reply this device can no longer open after a reinstall
    /// or new phone).
    ///
    /// This deliberately requires the caller to have obtained explicit user
    /// consent first: it forgets the previously trusted key so the **next** time
    /// this device sends, it re-establishes trust on the key the connection now
    /// advertises (trust-on-first-use), and pins that. It never silently accepts a
    /// new key mid-flight — the fail-closed seal guard still refuses to send until
    /// this is called — so the interception protection is preserved while giving
    /// the user a clean, honest way to recover a real reinstall / new device.
    func repinAgentKeyAfterUserConfirmation(for client: HermesGatewayClientRecord) {
        clearAgentKeyPin(clientId: client.id)
        setNotice(
            "Trust reset for \(client.displayName). Send a message to finish reconnecting privately.",
            style: .success
        )
    }

    var testButtonTitle: String {
        if isSendingTest { return "Queueing" }
        return selectedClient?.isOnline(relativeTo: statusNow) == true ? "Send and wait for reply" : "Queue test"
    }

    var noticeIcon: String {
        switch noticeStyle {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    func startGatewayListening(uid: String?) {
        syncSelectedClientIDFromDefaults()
        guard let uid, !uid.isEmpty else {
            stopGatewayListening()
            latestReply = nil
            pendingTestEvent = nil
            return
        }
        guard listenedUID != uid else {
            startStatusClockIfNeeded()
            return
        }
        stopGatewayListening()
        listenedUID = uid
        messageListenerStartedAt = Date()
        startStatusClockIfNeeded()
        clientListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("hermes_gateway_clients")
            .order(by: "updatedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleClientsSnapshot(snapshot: snapshot, error: error)
                }
            }
        messageListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("hermes_gateway_messages")
            .order(by: "createdAt", descending: true)
            .limit(to: 20)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleMessagesSnapshot(snapshot: snapshot, error: error)
                }
            }
        approvalListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("hermes_gateway_approvals")
            .order(by: "requestedAt", descending: true)
            .limit(to: 40)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleApprovalsSnapshot(snapshot: snapshot, error: error)
                }
            }
    }

    func stopGatewayListening() {
        clientListener?.remove()
        clientListener = nil
        messageListener?.remove()
        messageListener = nil
        approvalListener?.remove()
        approvalListener = nil
        statusClockTask?.cancel()
        statusClockTask = nil
        listenedUID = nil
        messageListenerStartedAt = nil
        openedGatewayAttachments = [:]
        failedGatewayAttachmentIDs = []
    }

    func refresh(isSignedIn: Bool) async {
        guard isSignedIn else {
            clients = []
            approvals = []
            persistSelectedClientID(nil)
            noticeText = nil
            pendingTestEvent = nil
            latestReply = nil
            return
        }
        guard !isLoading else { return }
        syncSelectedClientIDFromDefaults()
        failedGatewayAttachmentIDs = []
        isLoading = true
        defer { isLoading = false }

        do {
            clients = try await repository.listHermesGatewayClients()
            repairSelectedClientIfNeeded()
            noticeText = nil
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    @discardableResult
    func approve(userCode: String, displayName: String) async -> HermesGatewayClientRecord? {
        guard !isApproving else { return nil }
        isApproving = true
        defer { isApproving = false }

        do {
            let client = try await repository.approveHermesGatewayDeviceGrant(
                userCode: userCode,
                displayName: displayName
            )
            // Root the agent-key pin in the AUTHENTICATED approval, not relay TOFU.
            // `approveHermesGatewayDeviceGrant` is an AppCheck + auth-gated callable;
            // the `relayPublicKey` it returns is delivered over that authenticated
            // channel, so a relay cannot swap it post-approval. Re-pairing first
            // drops any stale pin (explicit operator re-trust), then we pin the
            // freshly-approved key IMMEDIATELY — so the very first seal authenticates
            // against a pairing-rooted key instead of one read from a relay-writable
            // client doc at send time (closes the first-pin poisoning window). The
            // out-of-band safety code (shown at pairing) remains the ultimate root
            // against a fully-compromised server, exactly like Signal's safety number.
            clearAgentKeyPin(clientId: client.id)
            var pinPersisted = true
            if let uid = listenedUID, !uid.isEmpty,
               let agentKey = client.relayPublicKey, !agentKey.isEmpty {
                // Fail-closed: `verifyOrPin` now reflects a Keychain WRITE failure
                // (it returns `.unknownKeychainError` rather than a phantom
                // `.pinnedFirstUse`). If the pairing-rooted pin could not be stored
                // durably, the out-of-band safety code is the fallback root and the
                // operator must verify it before trusting the link.
                pinPersisted = agentKeyPinStore.verifyOrPin(
                    agentPublicKeyBase64: agentKey, uid: uid, clientId: client.id
                ).allowsSeal
            }
            upsert(client)
            persistSelectedClientID(client.id)
            // Surface the out-of-band safety code at pairing: comparing it against
            // the code your Mac prints is what catches a server that tampered with
            // the very first key exchange (the one window the authenticated pin
            // above cannot close on its own). This is the Signal "safety number".
            // If the pin did not persist, the safety check is the ONLY root, so we
            // make the instruction emphatic.
            let safetyHint = agentSafetyCode(for: client).map {
                pinPersisted
                    ? " Safety code: \($0) — confirm it matches the code shown on your Mac."
                    : " IMPORTANT — this device couldn't store the pairing key securely, so you MUST verify the safety code: \($0) must match the code shown on your Mac before you trust this link."
            } ?? ""
            setNotice(
                "Hermes is paired.\(safetyHint) Now run `hermes gateway run`, or start/restart the installed gateway service, so Hermes is online to receive messages.",
                style: .warning
            )
            return client
        } catch {
            if isConsumedPairingCodeError(error) {
                await refreshClientsAfterPairingFailure()
                setNotice(
                    "That Hermes code has already been used or has expired. Generate a new code on your Mac, then enter it here.",
                    style: .warning
                )
                return nil
            }
            setNotice(error.localizedDescription, style: .error)
            return nil
        }
    }

    func revoke(_ client: HermesGatewayClientRecord) async {
        guard client.isActive, revokingClientId == nil else { return }
        revokingClientId = client.id
        defer { revokingClientId = nil }

        do {
            try await repository.revokeHermesGatewayClient(clientId: client.id)
            // Revoking ends this pairing; drop its pin so a future re-pair (which
            // may reuse the client id) trusts the new agent key on first use.
            clearAgentKeyPin(clientId: client.id)
            clients = clients.filter { $0.id != client.id }
            repairSelectedClientIfNeeded()
            setNotice("Hermes client revoked.", style: .success)
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    func pruneStaleClients() async {
        guard !isPruningStaleClients, revokingClientId == nil else { return }
        let staleClients = hiddenDuplicateClients
        guard !staleClients.isEmpty else {
            setNotice("There are no older Hermes gateway entries to remove.", style: .info)
            return
        }

        isPruningStaleClients = true
        defer {
            isPruningStaleClients = false
            revokingClientId = nil
        }

        var removedCount = 0
        var firstError: Error?

        for client in staleClients where client.isActive {
            revokingClientId = client.id
            do {
                try await repository.revokeHermesGatewayClient(clientId: client.id)
                clearAgentKeyPin(clientId: client.id)
                clients.removeAll { $0.id == client.id }
                removedCount += 1
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        repairSelectedClientIfNeeded()
        if let firstError {
            setNotice(
                "Removed \(removedCount) older Hermes gateway entr\(removedCount == 1 ? "y" : "ies"); one or more could not be removed: \(firstError.localizedDescription)",
                style: .warning
            )
        } else {
            setNotice(
                "Removed \(removedCount) older Hermes gateway entr\(removedCount == 1 ? "y" : "ies").",
                style: .success
            )
        }
    }

    func selectClient(_ client: HermesGatewayClientRecord) {
        guard client.isActive else {
            setNotice("That Hermes client has been revoked.", style: .warning)
            return
        }
        persistSelectedClientID(client.id)
        let online = client.isOnline(relativeTo: statusNow)
        setNotice(
            online
                ? "\(client.displayName) is selected for gateway messages."
                : "\(client.displayName) is selected. Messages will queue until it checks in.",
            style: online ? .success : .warning
        )
    }

    @discardableResult
    func sendGatewayMessage(text: String, senderDisplayName: String, threadId: String) async -> HermesGatewayQueuedEvent? {
        syncSelectedClientIDFromDefaults()
        guard let targetClient = selectedClient else {
            setNotice("Connect Hermes first.", style: .warning)
            return nil
        }
        guard targetClient.canSealToAgent else {
            setNotice(Self.gatewayE2EERequiredMessage(for: targetClient), style: .warning)
            return nil
        }
        guard !agentRelayKeyChanged(for: targetClient) else {
            setNotice(Self.gatewayRelayKeyChangedMessage(for: targetClient), style: .error)
            return nil
        }
        guard !isSendingGatewayMessage else { return nil }
        isSendingGatewayMessage = true
        defer { isSendingGatewayMessage = false }

        do {
            let event = try await repository.enqueueHermesGatewayEvent(
                text: text,
                threadId: threadId,
                targetClient: targetClient,
                targetClientId: targetClient.id,
                senderDisplayName: senderDisplayName
            )
            pendingTestEvent = event
            pendingEventSentAt = Date()
            statusNow = Date()
            latestReply = nil
            let targetOnline = targetClient.isOnline(relativeTo: statusNow)
            setNotice(
                targetOnline
                    ? "Message sent to \(targetClient.displayName) through BurnBar Cloud. Waiting for Hermes to reply."
                    : "Message queued for \(targetClient.displayName) in BurnBar Cloud. Hermes will pick it up when that gateway checks in.",
                style: targetOnline ? .info : .warning
            )
            return event
        } catch {
            setNotice(error.localizedDescription, style: .error)
            return nil
        }
    }

    @discardableResult
    func switchGatewayModel(modelId: String, senderDisplayName: String, threadId: String) async -> HermesGatewayQueuedEvent? {
        syncSelectedClientIDFromDefaults()
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setNotice("Type a model id first.", style: .warning)
            return nil
        }
        guard let targetClient = selectedClient else {
            setNotice("Connect Hermes first.", style: .warning)
            return nil
        }
        guard targetClient.canSealToAgent else {
            setNotice(Self.gatewayE2EERequiredMessage(for: targetClient), style: .warning)
            return nil
        }
        guard !agentRelayKeyChanged(for: targetClient) else {
            setNotice(Self.gatewayRelayKeyChangedMessage(for: targetClient), style: .error)
            return nil
        }
        guard !isSwitchingModel else { return nil }
        isSwitchingModel = true
        defer { isSwitchingModel = false }

        do {
            let event = try await repository.enqueueHermesGatewayModelSwitch(
                modelId: trimmed,
                threadId: threadId,
                targetClient: targetClient,
                targetClientId: targetClient.id,
                senderDisplayName: senderDisplayName
            )
            pendingModelSwitchEvent = event
            pendingTestEvent = event
            pendingEventSentAt = Date()
            statusNow = Date()
            latestReply = nil
            setNotice(
                "Model switch queued for \(targetClient.displayName): \(trimmed).",
                style: targetClient.isOnline(relativeTo: statusNow) ? .info : .warning
            )
            return event
        } catch {
            setNotice(error.localizedDescription, style: .error)
            return nil
        }
    }

    /// Flip a gateway client between supervised (every action gated) and
    /// autonomous oversight. `mode` must be "supervised" or "autonomous".
    func setOversight(clientId: String, mode: String, targetClient: HermesGatewayClientRecord? = nil) async {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else { return }
        guard settingOversightClientId == nil else { return }
        settingOversightClientId = trimmedClientId
        defer { settingOversightClientId = nil }

        do {
            try await repository.setHermesGatewayOversightMode(clientId: trimmedClientId, mode: mode, targetClient: targetClient)
            setNotice(
                mode == "autonomous"
                    ? "Autonomous mode on. This Hermes will run without per-action approval."
                    : "Supervised mode on. This Hermes will wait for your approval on gated actions.",
                style: mode == "autonomous" ? .warning : .success
            )
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    /// Approve or reject an armed oversight gate. The decision is bound to this
    /// trusted native escrow device (same path as CLI-mission approvals) so a
    /// stolen owner token cannot self-approve a gated gateway action.
    func respondToApproval(approvalId: String, approve: Bool) async {
        let trimmedApprovalId = approvalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApprovalId.isEmpty else { return }
        guard respondingApprovalId == nil else { return }
        respondingApprovalId = trimmedApprovalId
        defer { respondingApprovalId = nil }

        let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
        do {
            try await repository.respondHermesGatewayApproval(
                approvalId: trimmedApprovalId,
                approve: approve,
                deviceId: deviceId
            )
            if let client = selectedClient, client.canSealToAgent {
                try await repository.enqueueHermesGatewayApprovalDecision(
                    approvalId: trimmedApprovalId,
                    approve: approve,
                    targetClient: client,
                    targetClientId: client.id
                )
            }
            setNotice(
                approve ? "Action approved. Hermes will continue." : "Action rejected.",
                style: approve ? .success : .warning
            )
        } catch {
            setNotice(error.localizedDescription, style: .error)
        }
    }

    func isRespondingToApproval(_ approval: HermesGatewayApprovalRecord) -> Bool {
        respondingApprovalId == approval.id
    }

    func isSettingOversight(_ client: HermesGatewayClientRecord) -> Bool {
        settingOversightClientId == client.id
    }

    @discardableResult
    func sendTest(text: String, senderDisplayName: String) async -> Bool {
        syncSelectedClientIDFromDefaults()
        guard let targetClient = selectedClient else {
            setNotice("Connect Hermes first.", style: .warning)
            return false
        }
        guard !isSendingTest else { return false }
        isSendingTest = true
        defer { isSendingTest = false }

        do {
            let event = try await repository.enqueueHermesGatewayEvent(
                text: text,
                targetClient: targetClient,
                targetClientId: targetClient.id,
                senderDisplayName: senderDisplayName
            )
            pendingTestEvent = event
            pendingEventSentAt = Date()
            statusNow = Date()
            latestReply = nil
            let targetOnline = targetClient.isOnline(relativeTo: statusNow)
            let message = targetOnline
                ? "Event #\(event.sequence) is queued for \(targetClient.displayName). Waiting for Hermes to reply."
                : "Event #\(event.sequence) is queued for \(targetClient.displayName). Open or restart that gateway client so it can pick up the message."
            setNotice(message, style: targetOnline ? .info : .warning)
            return true
        } catch {
            setNotice(error.localizedDescription, style: .error)
            return false
        }
    }

    private func handleClientsSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            setNotice("Could not watch Hermes gateway clients: \(error.localizedDescription)", style: .error)
            return
        }
        clients = snapshot?.documents.compactMap { document in
            HermesGatewayClientRecord(documentID: document.documentID, data: document.data())
        } ?? []
        statusNow = Date()
        syncSelectedClientIDFromDefaults()
        repairSelectedClientIfNeeded()
    }

    private func handleMessagesSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            setNotice("Could not watch Hermes replies: \(error.localizedDescription)", style: .error)
            return
        }
        // Open sealed replies with this phone's relay key before resolving/rendering.
        // Legacy plaintext docs pass through unchanged; a doc this device cannot
        // open keeps `resolvedText == nil` and renders the sealed-for-another-device
        // state instead of empty.
        let keypair: HermesGatewayRelayKeypair
        do {
            keypair = try HermesGatewayRelayKeypair.loadOrCreate()
        } catch {
            setNotice("Could not open Hermes replies: \(error.localizedDescription)", style: .error)
            return
        }
        let messages = (snapshot?.documents.compactMap { document in
            HermesGatewayMessageRecord(documentID: document.documentID, data: document.data())
        } ?? []).map { record -> HermesGatewayMessageRecord in
            guard let uid = listenedUID, !uid.isEmpty else { return record }
            let targetClient = clients.first { $0.id == record.clientId }
            // Pass the shared pin store so an unsealed reply on a client whose agent
            // key this device pinned is treated as a downgrade (never rendered as a
            // genuine reply) — closes the server-injected-plaintext impersonation gap.
            return record.decodedText(using: keypair, uid: uid, targetClient: targetClient, pinStore: agentKeyPinStore)
        }

        let approvalDetails = HermesGatewayApprovalDetailIndex.keyedByApprovalTarget(from: messages)
        // handleMessagesSnapshot already runs on the MainActor, so write the keyed
        // map inline (no redundant Task hop); keyed by the approval client/action.
        for (key, detail) in approvalDetails { sealedApprovalDetails[key] = detail }

        if let pendingTestEvent {
            guard let reply = HermesGatewayMessageResolver.newestReply(
                for: pendingTestEvent,
                in: messages,
                threadID: gatewayThreadID,
                targetClientId: pendingTestEvent.targetClientId ?? selectedTargetClientId,
                pendingEventSentAt: pendingEventSentAt
            ) else { return }
            Task { @MainActor in
                let hydrated = await hydrateGatewayAttachments(for: reply)
                latestReply = hydrated
                recordReplyInHermesThread(hydrated)
                self.pendingTestEvent = nil
                pendingEventSentAt = nil
                setNotice("Hermes replied. The gateway is working end to end.", style: .success)
                HapticBus.milestone()
                presentReplyNotification(hydrated)
            }
            return
        }

        guard let reply = HermesGatewayMessageResolver.newestThreadReply(
            in: messages,
            threadID: gatewayThreadID,
            targetClientId: selectedTargetClientId
        ) else { return }
        Task { @MainActor in
            let hydrated = await hydrateGatewayAttachments(for: reply)
            let isNewReply = latestReply?.id != hydrated.id
            latestReply = hydrated
            recordReplyInHermesThread(hydrated)
            if isNewReply,
               HermesGatewayMessageResolver.wasCreatedWhileListening(
                    hydrated,
                    listenerStartedAt: messageListenerStartedAt
               ) {
                setNotice("Hermes replied. The gateway is working end to end.", style: .success)
                HapticBus.milestone()
                presentReplyNotification(hydrated)
            }
        }
    }

    private func hydrateGatewayAttachments(for reply: HermesGatewayMessageRecord) async -> HermesGatewayMessageRecord {
        guard !reply.attachmentIds.isEmpty,
              let uid = listenedUID, !uid.isEmpty
        else { return reply }

        var opened: [HermesAttachment] = []
        var failed: [String] = []
        for attachmentId in reply.attachmentIds {
            if let cached = openedGatewayAttachments[attachmentId] {
                opened.append(cached)
                continue
            }
            if failedGatewayAttachmentIDs.contains(attachmentId) {
                failed.append(attachmentId)
                continue
            }
            guard let attachment = await openGatewayAttachment(
                attachmentId: attachmentId,
                uid: uid,
                clientId: reply.clientId
            ) else {
                failedGatewayAttachmentIDs.insert(attachmentId)
                failed.append(attachmentId)
                continue
            }
            openedGatewayAttachments[attachmentId] = attachment
            opened.append(attachment)
        }
        return reply.withAttachmentHydration(opened: opened, failedAttachmentIds: failed)
    }

    private func openGatewayAttachment(attachmentId: String, uid: String, clientId: String) async -> HermesAttachment? {
        do {
            guard let data = try await fetchGatewayAttachmentDocument(uid: uid, attachmentId: attachmentId),
                  let record = HermesGatewayAttachmentRecord(documentID: attachmentId, data: data),
                  record.clientId == clientId,
                  let storagePath = record.bodyStoragePath,
                  !storagePath.isEmpty
            else { return nil }

            let sealedBody = try await downloadGatewayAttachmentBody(record: record)
            let keypair = try HermesGatewayRelayKeypair.loadOrCreate()
            // v2: bind the AGENT's pinned relay key so a forged attachment fails
            // the authenticated unwrap. Fail closed if unpinned.
            guard let opened = record.opened(
                downloadedBody: sealedBody, using: keypair, uid: uid,
                pinnedSenderKey: agentKeyPinStore.pinnedKey(uid: uid, clientId: clientId)
            ) else {
                return nil
            }
            return try HermesAttachmentLoader.importGatewayOpenedAttachment(opened, threadID: gatewayThreadID)
        } catch {
            return nil
        }
    }

    private func fetchGatewayAttachmentDocument(uid: String, attachmentId: String) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { continuation in
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("hermes_gateway_attachments").document(attachmentId)
                .getDocument { snapshot, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: snapshot?.data())
                }
        }
    }

    private func downloadGatewayAttachmentBody(record: HermesGatewayAttachmentRecord) async throws -> Data {
        let url = try await repository.hermesGatewayAttachmentDownloadURL(
            attachmentId: record.id,
            clientId: record.clientId,
            destinationId: record.destinationId
        )
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              Int64(data.count) <= Self.maxGatewayAttachmentDownloadBytes else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return data
    }

    private func handleApprovalsSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            setNotice("Could not watch Hermes approvals: \(error.localizedDescription)", style: .error)
            return
        }
        approvals = snapshot?.documents.compactMap { document in
            HermesGatewayApprovalRecord(documentID: document.documentID, data: document.data())
        } ?? []
        statusNow = Date()
    }

    private func presentReplyNotification(_ reply: HermesGatewayMessageRecord) {
        guard lastNotifiedMessageID != reply.id else { return }
        lastNotifiedMessageID = reply.id
        let modelID = gatewayReplyModelID()
        AgentReplyNotificationService.shared.presentLocalReply(
            id: reply.id,
            title: "Hermes replied",
            // Same source of truth as the chat thread: a reply this device can't
            // open surfaces the calm re-pair line, never an empty preview.
            preview: reply.chatRenderText(emptyFallback: "Hermes sent a reply through BurnBar Cloud."),
            runtime: AssistantRuntimeID.hermes.rawValue,
            threadID: gatewayThreadID,
            provider: gatewayReplyModelProvider(modelID: modelID)
        )
    }

    private func recordReplyInHermesThread(_ reply: HermesGatewayMessageRecord) {
        let modelID = gatewayReplyModelID()
        HermesService.shared.recordBurnBarGatewayReply(
            reply,
            threadID: gatewayThreadID,
            modelID: modelID,
            modelName: modelID
        )
    }

    private func gatewayReplyModelID() -> String {
        nonEmpty(runtimeModelId)
            ?? "hermes"
    }

    private func gatewayReplyModelProvider(modelID: String) -> AgentProvider? {
        hermesGatewayReplyModelProvider(
            providerID: nonEmpty(selectedClient?.runtimeProviderId),
            modelID: modelID
        )
    }

    func isRevoking(_ client: HermesGatewayClientRecord) -> Bool {
        revokingClientId == client.id
    }

    func isOnline(_ client: HermesGatewayClientRecord) -> Bool {
        client.isOnline(relativeTo: statusNow)
    }

    func setNotice(_ text: String, style: HermesGatewayNoticeStyle) {
        noticeText = text
        noticeStyle = style
    }

    private func upsert(_ client: HermesGatewayClientRecord) {
        clients.removeAll { $0.id == client.id }
        clients.insert(client, at: 0)
        repairSelectedClientIfNeeded()
    }

    private func isConsumedPairingCodeError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("pairing code was not found")
    }

    private func refreshClientsAfterPairingFailure() async {
        do {
            clients = try await repository.listHermesGatewayClients()
            statusNow = Date()
            repairSelectedClientIfNeeded()
        } catch {
            hermesSettingsLogger.error("Failed to refresh gateway clients after pairing failure: \(error.localizedDescription)")
        }
    }

    private func repairSelectedClientIfNeeded() {
        let visible = displayClients
        guard !visible.isEmpty else {
            persistSelectedClientID(nil)
            return
        }
        if let selectedClientId,
           visible.contains(where: { $0.id == selectedClientId }) {
            return
        }
        persistSelectedClientID(onlineClients.first?.id ?? visible.first?.id)
    }

    private func syncSelectedClientIDFromDefaults() {
        let stored = defaults.string(forKey: Self.selectedClientDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (stored?.isEmpty == false) ? stored : nil
        if normalized != selectedClientId {
            selectedClientId = normalized
            clearGatewayConversationStateForTargetChange()
        }
    }

    private func persistSelectedClientID(_ clientId: String?) {
        let previous = selectedClientId
        let trimmed = clientId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            selectedClientId = trimmed
            defaults.set(trimmed, forKey: Self.selectedClientDefaultsKey)
        } else {
            selectedClientId = nil
            defaults.removeObject(forKey: Self.selectedClientDefaultsKey)
        }
        if previous != selectedClientId {
            clearGatewayConversationStateForTargetChange()
        }
    }

    private func clearGatewayConversationStateForTargetChange() {
        pendingTestEvent = nil
        pendingModelSwitchEvent = nil
        pendingEventSentAt = nil
        latestReply = nil
        lastNotifiedMessageID = nil
    }

    private func startStatusClockIfNeeded() {
        guard statusClockTask == nil else { return }
        statusNow = Date()
        statusClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.statusNow = Date()
            }
        }
    }

}
