import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore

/// Listens to the public envelope at `ops/computer_use_budget_status/state/current`.
/// Operator USD metrics live at `metrics/current` (ADR 006) and are not read here.
@MainActor
final class ComputerUseBudgetStatusStore {
    private var listener: ListenerRegistration?
    private(set) var latestEnvelope: ComputerUseBudgetEnvelope?
    private(set) var lastKnownEnvelope: ComputerUseBudgetEnvelope?
    private(set) var failClosedDueToPermissionDenied = false
    private(set) var hasAuthoritativeSnapshot = false
    private(set) var authorityProvenance: ComputerUseAuthorityProvenance?

    var onEnvelopeChanged: ((ComputerUseBudgetEnvelope) -> Void)?
    var onAvailabilityChanged: (() -> Void)?

    private let documentPath: String
    private let isSignedInProvider: @Sendable () -> Bool

    init(
        documentPath: String = "ops/computer_use_budget_status/state/current",
        isSignedInProvider: @escaping @Sendable () -> Bool = {
            Auth.auth().currentUser != nil
        }
    ) {
        self.documentPath = documentPath
        self.isSignedInProvider = isSignedInProvider
    }

    func startListening() {
        guard listener == nil else { return }
        guard FirebaseApp.app() != nil else { return }
        listener = Firestore.firestore()
            .document(documentPath)
            .addSnapshotListener { [weak self] snapshot, error in
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
            let snapshot = try await Firestore.firestore()
                .document(documentPath)
                .getDocument(source: .server)
            handleSnapshotData(
                snapshot.data(),
                isFromCache: snapshot.metadata.isFromCache,
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

    func handleSnapshot(snapshot: DocumentSnapshot?, error: Error?) {
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
        handleSnapshotData(
            snapshot.data(),
            isFromCache: snapshot.metadata.isFromCache,
            observedAt: Date()
        )
    }

    func handleSnapshotData(
        _ data: [String: Any]?,
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
        guard let data else {
            hasAuthoritativeSnapshot = false
            authorityProvenance = nil
            onAvailabilityChanged?()
            return
        }
        let envelope = Self.parsePublicEnvelope(data)
        let upstreamUpdatedAt = Self.parseDate(data["updatedAt"])
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
        applyPublicEnvelopeData(data)
    }

    func applyPublicEnvelopeData(_ data: [String: Any]) {
        let envelope = Self.parsePublicEnvelope(data)
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

    static func parsePublicEnvelope(_ data: [String: Any]) -> ComputerUseBudgetEnvelope {
        let levelRaw = data["level"] as? String ?? ComputerUseBudgetEnvelope.Level.normal.rawValue
        let level = ComputerUseBudgetEnvelope.Level(rawValue: levelRaw) ?? .normal
        return ComputerUseBudgetEnvelope(
            level: level,
            projectedMonthEndUSD: 0,
            monthToDateUSD: 0,
            activeActionsPerRun: data["activeActionsPerRun"] as? Int ?? 0,
            activeActionsPerDay: data["activeActionsPerDay"] as? Int ?? 0,
            activeSessionsPerDay: data["activeSessionsPerDay"] as? Int ?? 0,
            perUserDailySpendCeilingUSD: data["perUserDailySpendCeilingUSD"] as? Double ?? 0,
            updatedAt: parseDate(data["updatedAt"]) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        switch raw {
        case let timestamp as Timestamp: return timestamp.dateValue()
        case let date as Date: return date
        case let seconds as TimeInterval: return Date(timeIntervalSince1970: seconds)
        case let int as Int: return Date(timeIntervalSince1970: TimeInterval(int))
        default: return nil
        }
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
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var listenerDayKey: String?
    private var authoritativeDayKey: String?
    private(set) var currentUsage: ComputerUseQuotaUsage?
    private(set) var authorityProvenance: ComputerUseAuthorityProvenance?
    var hasAuthoritativeSnapshot: Bool {
        authoritativeDayKey == Self.todayKey()
    }
    var onStateChanged: (() -> Void)?

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
            let snapshot = try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("computer_use_quota_usage").document(dayKey)
                .getDocument(source: .server)
            handleSnapshot(
                documentExists: snapshot.exists,
                data: snapshot.data(),
                error: nil,
                dayKey: dayKey,
                isFromCache: snapshot.metadata.isFromCache,
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
        listener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("computer_use_quota_usage").document(dayKey)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self,
                          self.listenerUID == uid,
                          self.listenerDayKey == dayKey else { return }
                    self.handleSnapshot(
                        documentExists: snapshot?.exists,
                        data: snapshot?.data(),
                        error: error,
                        dayKey: dayKey,
                        isFromCache: snapshot?.metadata.isFromCache ?? true
                    )
                }
            }
    }

    func handleSnapshot(
        documentExists: Bool?,
        data: [String: Any]?,
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
            guard let data else {
                currentUsage = nil
                authoritativeDayKey = nil
                authorityProvenance = nil
                onStateChanged?()
                return
            }
            currentUsage = Self.parse(data, fallbackDayKey: dayKey)
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

    static func parse(_ data: [String: Any], fallbackDayKey: String) -> ComputerUseQuotaUsage {
        ComputerUseQuotaUsage(
            dayKey: data["dayKey"] as? String ?? fallbackDayKey,
            browserActionsExecuted: data["browserActionsExecuted"] as? Int ?? 0,
            browserActionsRejected: data["browserActionsRejected"] as? Int ?? 0,
            systemActionsExecuted: data["systemActionsExecuted"] as? Int ?? 0,
            systemActionsRejected: data["systemActionsRejected"] as? Int ?? 0,
            phoneControlIntentsExecuted: data["phoneControlIntentsExecuted"] as? Int ?? 0,
            phoneControlIntentsRejected: data["phoneControlIntentsRejected"] as? Int ?? 0,
            sessionsStarted: data["sessionsStarted"] as? Int ?? 0,
            sessionsCompleted: data["sessionsCompleted"] as? Int ?? 0,
            totalSessionSeconds: data["totalSessionSeconds"] as? Int ?? 0,
            visionModelSpendUSD: data["visionModelSpendUSD"] as? Double ?? 0,
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue()
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
