import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore

/// Listens to the public envelope at `ops/computer_use_budget_status/state/current`.
/// Operator USD metrics live at `metrics/current` (ADR 006) and are not read here.
@MainActor
final class ComputerUseBudgetStatusStore {
    private var listener: (any ComputerUseFirestoreListenerRegistration)?
    private(set) var latestEnvelope: ComputerUseBudgetEnvelope?
    private(set) var lastKnownEnvelope: ComputerUseBudgetEnvelope?
    private(set) var failClosedDueToPermissionDenied = false
    private(set) var hasAuthoritativeSnapshot = false
    private(set) var authorityProvenance: ComputerUseAuthorityProvenance?

    var onEnvelopeChanged: ((ComputerUseBudgetEnvelope) -> Void)?
    var onAvailabilityChanged: (() -> Void)?

    private let documentPath: String
    private let isSignedInProvider: @Sendable () -> Bool
    private let firestoreGateway: any ComputerUseFirestoreGateway

    init(
        documentPath: String = "ops/computer_use_budget_status/state/current",
        isSignedInProvider: @escaping @Sendable () -> Bool = {
            Auth.auth().currentUser != nil
        },
        firestoreGateway: any ComputerUseFirestoreGateway = ComputerUseFirestoreLiveGateway()
    ) {
        self.documentPath = documentPath
        self.isSignedInProvider = isSignedInProvider
        self.firestoreGateway = firestoreGateway
    }

    func startListening() {
        guard listener == nil else { return }
        guard FirebaseApp.app() != nil else { return }
        listener = firestoreGateway.addSnapshotListener(at: documentPath) { [weak self] snapshot, error in
            Task { @MainActor in
                self?.handleSnapshot(snapshot: snapshot, error: error)
            }
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    func refreshFromServerIfNeeded(now: Date = Date()) async {
        if let authorityProvenance,
           now.timeIntervalSince(authorityProvenance.observedAt)
            < ComputerUseCapabilityFreshness.maximumSourceObservationAge / 2 {
            return
        }
        guard FirebaseApp.app() != nil else { return }
        do {
            let snapshot = try await firestoreGateway.getDocumentFromServer(at: documentPath)
            handleSnapshotPayload(
                snapshot.payload,
                isFromCache: snapshot.isFromCache,
                observedAt: now
            )
        } catch {
            handleListenerError(error, notifyAvailability: false)
        }
    }

    /// Envelope for admission decisions — respects fail-closed and last-known cache.
    var effectiveEnvelope: ComputerUseBudgetEnvelope {
        if failClosedDueToPermissionDenied, let lastKnownEnvelope {
            return lastKnownEnvelope
        }
        return latestEnvelope ?? lastKnownEnvelope ?? .initialNormal
    }

    func handleSnapshot(snapshot: ComputerUseFirestoreDocumentSnapshot?, error: Error?) {
        if let error {
            handleListenerError(error)
            return
        }
        failClosedDueToPermissionDenied = false
        guard let snapshot else {
            hasAuthoritativeSnapshot = false
            authorityProvenance = nil
            onAvailabilityChanged?()
            return
        }
        handleSnapshotPayload(
            snapshot.payload,
            isFromCache: snapshot.isFromCache,
            observedAt: Date()
        )
    }

    func handleSnapshotPayload(
        _ payload: ComputerUseFirestorePayload?,
        isFromCache: Bool,
        observedAt: Date
    ) {
        guard !isFromCache else {
            if authorityProvenance == nil {
                hasAuthoritativeSnapshot = false
                onAvailabilityChanged?()
            }
            return
        }
        guard let payload else {
            hasAuthoritativeSnapshot = false
            authorityProvenance = nil
            onAvailabilityChanged?()
            return
        }
        let envelope = Self.parsePublicEnvelope(payload)
        let upstreamUpdatedAt = payload.date("updatedAt")
        guard let upstreamUpdatedAt else {
            hasAuthoritativeSnapshot = false
            authorityProvenance = nil
            latestEnvelope = envelope
            onAvailabilityChanged?()
            return
        }
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: observedAt,
            updatedAt: upstreamUpdatedAt
        )
        hasAuthoritativeSnapshot = true
        authorityProvenance = provenance
        applyPublicEnvelope(payload)
    }

    func applyPublicEnvelope(_ payload: ComputerUseFirestorePayload) {
        let envelope = Self.parsePublicEnvelope(payload)
        latestEnvelope = envelope
        lastKnownEnvelope = envelope
        onEnvelopeChanged?(envelope)
    }

    private func handleListenerError(
        _ error: Error,
        notifyAvailability: Bool = true
    ) {
        let nsError = error as NSError
        hasAuthoritativeSnapshot = false
        authorityProvenance = nil
        if notifyAvailability {
            onAvailabilityChanged?()
        }
        let code = FirestoreErrorCode.Code(rawValue: nsError.code)
        AppLogger.sync.error(
            "computer_use_budget_listener_failed",
            metadata: [
                "error": error.localizedDescription,
                "code": String(describing: code)
            ]
        )

        switch code {
        case .permissionDenied where isSignedInProvider():
            failClosedDueToPermissionDenied = true
            if lastKnownEnvelope == nil {
                latestEnvelope = nil
            }
        case .unavailable, .deadlineExceeded, .resourceExhausted:
            failClosedDueToPermissionDenied = false
        default:
            failClosedDueToPermissionDenied = false
        }
    }

    static func parsePublicEnvelope(_ payload: ComputerUseFirestorePayload) -> ComputerUseBudgetEnvelope {
        let levelRaw = payload.string("level") ?? ComputerUseBudgetEnvelope.Level.normal.rawValue
        let level = ComputerUseBudgetEnvelope.Level(rawValue: levelRaw) ?? .normal
        return ComputerUseBudgetEnvelope(
            level: level,
            projectedMonthEndUSD: 0,
            monthToDateUSD: 0,
            activeActionsPerRun: payload.int("activeActionsPerRun") ?? 0,
            activeActionsPerDay: payload.int("activeActionsPerDay") ?? 0,
            activeSessionsPerDay: payload.int("activeSessionsPerDay") ?? 0,
            perUserDailySpendCeilingUSD: payload.double("perUserDailySpendCeilingUSD") ?? 0,
            updatedAt: payload.date("updatedAt") ?? Date(timeIntervalSince1970: 0)
        )
    }
}

/// Live mirror of the server-reconciled daily Computer Use counters at
/// `users/{uid}/computer_use_quota_usage/{YYYY-MM-DD}`.
///
/// A successful missing-document snapshot is authoritative zero usage for that
/// UTC day. Listener failures and missing snapshots remain unavailable so the
/// daemon projection cannot silently turn "not loaded" into unlimited usage.
@MainActor
final class ComputerUseQuotaUsageStore {
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listener: (any ComputerUseFirestoreListenerRegistration)?
    private var listenerUID: String?
    private var listenerDayKey: String?
    private var authoritativeDayKey: String?
    private(set) var currentUsage: ComputerUseQuotaUsage?
    private(set) var authorityProvenance: ComputerUseAuthorityProvenance?
    var hasAuthoritativeSnapshot: Bool {
        authoritativeDayKey == Self.todayKey()
    }
    var onStateChanged: (() -> Void)?
    private let firestoreGateway: any ComputerUseFirestoreGateway

    init(firestoreGateway: any ComputerUseFirestoreGateway = ComputerUseFirestoreLiveGateway()) {
        self.firestoreGateway = firestoreGateway
    }

    func startListening() {
        guard FirebaseApp.app() != nil else { return }
        if authHandle == nil {
            authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                Task { @MainActor in
                    guard let self else { return }
                    let dayKey = ComputerUseQuotaUsageStore.todayKey()
                    guard self.listenerUID != user?.uid || self.listenerDayKey != dayKey else { return }
                    self.restart(uid: user?.uid, dayKey: dayKey)
                }
            }
        }
        let uid = Auth.auth().currentUser?.uid
        let today = Self.todayKey()
        if listenerUID != uid || listenerDayKey != today {
            restart(uid: uid, dayKey: today)
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        authHandle = nil
        listenerUID = nil
        listenerDayKey = nil
        authoritativeDayKey = nil
        currentUsage = nil
        authorityProvenance = nil
        onStateChanged?()
    }

    func refreshFromServerIfNeeded(now: Date = Date()) async {
        if let authorityProvenance,
           now.timeIntervalSince(authorityProvenance.observedAt)
            < ComputerUseCapabilityFreshness.maximumSourceObservationAge / 2 {
            return
        }
        guard FirebaseApp.app() != nil,
              let uid = Auth.auth().currentUser?.uid,
              !uid.isEmpty else { return }
        let dayKey = Self.todayKey(now: now)
        do {
            let snapshot = try await firestoreGateway.getDocumentFromServer(
                at: "users/\(uid)/computer_use_quota_usage/\(dayKey)"
            )
            handleSnapshot(
                documentExists: snapshot.exists,
                payload: snapshot.payload,
                error: nil,
                dayKey: dayKey,
                isFromCache: snapshot.isFromCache,
                observedAt: now
            )
        } catch {
            currentUsage = nil
            authoritativeDayKey = nil
            authorityProvenance = nil
        }
    }

    private func restart(uid: String?, dayKey: String) {
        listener?.remove()
        listener = nil
        listenerUID = uid
        listenerDayKey = dayKey
        authoritativeDayKey = nil
        currentUsage = nil
        authorityProvenance = nil
        onStateChanged?()
        guard let uid, !uid.isEmpty else { return }
        listener = firestoreGateway.addSnapshotListener(
            at: "users/\(uid)/computer_use_quota_usage/\(dayKey)"
        ) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self,
                      self.listenerUID == uid,
                      self.listenerDayKey == dayKey else { return }
                self.handleSnapshot(
                    documentExists: snapshot?.exists,
                    payload: snapshot?.payload,
                    error: error,
                    dayKey: dayKey,
                    isFromCache: snapshot?.isFromCache ?? true
                )
            }
        }
    }

    func handleSnapshot(
        documentExists: Bool?,
        payload: ComputerUseFirestorePayload?,
        error: Error?,
        dayKey: String,
        isFromCache: Bool = false,
        observedAt: Date = Date()
    ) {
        guard error == nil, let documentExists else {
            currentUsage = nil
            authoritativeDayKey = nil
            authorityProvenance = nil
            onStateChanged?()
            return
        }
        guard !isFromCache else {
            if authorityProvenance == nil {
                currentUsage = nil
                authoritativeDayKey = nil
                onStateChanged?()
            }
            return
        }

        if documentExists {
            guard let payload else {
                currentUsage = nil
                authoritativeDayKey = nil
                authorityProvenance = nil
                onStateChanged?()
                return
            }
            currentUsage = Self.parse(payload, fallbackDayKey: dayKey)
        } else {
            currentUsage = ComputerUseQuotaUsage(dayKey: dayKey)
        }
        authoritativeDayKey = dayKey
        authorityProvenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: observedAt,
            updatedAt: currentUsage?.updatedAt
        )
        onStateChanged?()
    }

    static func parse(_ payload: ComputerUseFirestorePayload, fallbackDayKey: String) -> ComputerUseQuotaUsage {
        ComputerUseQuotaUsage(
            dayKey: payload.string("dayKey") ?? fallbackDayKey,
            browserActionsExecuted: payload.int("browserActionsExecuted") ?? 0,
            browserActionsRejected: payload.int("browserActionsRejected") ?? 0,
            systemActionsExecuted: payload.int("systemActionsExecuted") ?? 0,
            systemActionsRejected: payload.int("systemActionsRejected") ?? 0,
            phoneControlIntentsExecuted: payload.int("phoneControlIntentsExecuted") ?? 0,
            phoneControlIntentsRejected: payload.int("phoneControlIntentsRejected") ?? 0,
            sessionsStarted: payload.int("sessionsStarted") ?? 0,
            sessionsCompleted: payload.int("sessionsCompleted") ?? 0,
            totalSessionSeconds: payload.int("totalSessionSeconds") ?? 0,
            visionModelSpendUSD: payload.double("visionModelSpendUSD") ?? 0,
            updatedAt: payload.date("updatedAt")
        )
    }

    static func todayKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
