#if canImport(ActivityKit)
@preconcurrency import ActivityKit
import Foundation
import OpenBurnBarCore
import os.log

enum AgentWatchLiveActivityPushType: Equatable, Sendable {
    case token
    case none
}

/// Why `aps-environment` could not be read from a public artifact.
/// This is the named local-only fallback — not a silent `false`.
enum APSEnvironmentEntitlementUndetectableReason: String, Equatable, Sendable {
    /// No `embedded.mobileprovision` and no bundled entitlements plist.
    case missingEmbeddedProfile
    /// The profile or plist existed but was not a readable entitlements dict.
    case unreadableProfile
    /// Source `CODE_SIGN_ENTITLEMENTS` still has `$(APS_ENVIRONMENT)`.
    case unresolvedBuildPlaceholder
}

enum APSEnvironmentEntitlementOutcome: Equatable, Sendable {
    case present(String)
    case absent
    case undetectable(APSEnvironmentEntitlementUndetectableReason)

    var canRequestTokenPush: Bool {
        guard case .present(let environment) = self else { return false }
        return Self.isResolvedEnvironment(environment)
    }

    static func isResolvedEnvironment(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }
}

/// Public `aps-environment` probe. Does **not** call `SecTaskCreateFromSelf`
/// (not in the public iPhoneOS 27 SDK). Reads the signed
/// `embedded.mobileprovision` in the app bundle, or a bundled entitlements
/// plist (the processed `CODE_SIGN_ENTITLEMENTS` copy).
enum APSEnvironmentEntitlementProbe {
    static func inspect(bundle: Bundle = .main) -> APSEnvironmentEntitlementOutcome {
        inspect(
            profileData: data(named: "embedded", extension: "mobileprovision", in: bundle),
            entitlementsPlistData: bundledEntitlementsPlist(in: bundle)
        )
    }

    static func inspect(
        profileData: Data?,
        entitlementsPlistData: Data?
    ) -> APSEnvironmentEntitlementOutcome {
        if let profileData {
            let fromProfile = parseMobileProvision(profileData)
            switch fromProfile {
            case .present, .absent, .undetectable(.unresolvedBuildPlaceholder):
                return fromProfile
            case .undetectable:
                break
            }
        }
        if let entitlementsPlistData {
            return parseEntitlementsDictionary(
                data: entitlementsPlistData,
                wrappedInProfile: false
            )
        }
        return profileData == nil
            ? .undetectable(.missingEmbeddedProfile)
            : .undetectable(.unreadableProfile)
    }

    private static func bundledEntitlementsPlist(in bundle: Bundle) -> Data? {
        data(named: "OpenBurnBarMobile", extension: "entitlements", in: bundle)
            ?? data(named: "embedded-entitlements", extension: "plist", in: bundle)
    }

    private static func data(named name: String, extension ext: String, in bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func parseMobileProvision(_ data: Data) -> APSEnvironmentEntitlementOutcome {
        guard let plistData = extractPlistPayload(from: data) else {
            return .undetectable(.unreadableProfile)
        }
        return parseEntitlementsDictionary(data: plistData, wrappedInProfile: true)
    }

    private static func extractPlistPayload(from cms: Data) -> Data? {
        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = cms.range(of: startMarker),
              let end = cms.range(of: endMarker, in: start.lowerBound..<cms.endIndex)
        else { return nil }
        return Data(cms[start.lowerBound..<end.upperBound])
    }

    private static func parseEntitlementsDictionary(
        data: Data,
        wrappedInProfile: Bool
    ) -> APSEnvironmentEntitlementOutcome {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? NSDictionary else {
            return .undetectable(.unreadableProfile)
        }
        let entitlements: NSDictionary
        if wrappedInProfile {
            guard let inner = root["Entitlements"] as? NSDictionary else {
                return .undetectable(.unreadableProfile)
            }
            entitlements = inner
        } else {
            entitlements = root
        }
        guard let raw = entitlements["aps-environment"] else {
            return .absent
        }
        guard let value = raw as? String else {
            return .undetectable(.unreadableProfile)
        }
        if APSEnvironmentEntitlementOutcome.isResolvedEnvironment(value) {
            return .present(value)
        }
        return .undetectable(.unresolvedBuildPlaceholder)
    }
}

struct AgentWatchLiveActivityPushCapability: Equatable, Sendable {
    var canRequestTokenPush: Bool

    static var system: Self {
        Self(canRequestTokenPush: Self.hasTokenPushPath)
    }

    /// iOS 16.2+ `PushType.token` plus a resolved `aps-environment` on the
    /// running binary. `.undetectable` stays local-only
    /// (“Updates while OpenBurnBar is open”).
    private static var hasTokenPushPath: Bool {
        guard #available(iOS 16.2, *) else { return false }
        return APSEnvironmentEntitlementProbe.inspect().canRequestTokenPush
    }
}

@MainActor
protocol AgentWatchLiveActivityPushTokenSinking: AnyObject {
    func persist(sessionId: String, tokenHex: String) async
}

@available(iOS 16.1, *)
@MainActor
final class AgentWatchLiveActivityManager {
    static let shared = AgentWatchLiveActivityManager()
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "AgentWatchLiveActivityManager")

    private let backend: any AgentWatchLiveActivityBackend
    private let pushCapability: AgentWatchLiveActivityPushCapability
    private let tokenSink: (any AgentWatchLiveActivityPushTokenSinking)?
    private var lastState: AgentWatchLiveActivityAttributes.ContentState?
    private(set) var appliedPushType: AgentWatchLiveActivityPushType = .none
    /// Derived from the live content state: the push token is exactly what
    /// flips `remoteRefreshEnabled` on, and `end()` / `request()` clear the
    /// state. Keeping it computed removes three assignments that had to stay
    /// in lockstep.
    var hasPushToken: Bool { lastState?.remoteRefreshEnabled == true }
    var hasActiveActivity: Bool { backend.activeSessionId != nil }

    init(
        backend: any AgentWatchLiveActivityBackend = ActivityKitAgentWatchLiveActivityBackend(),
        pushCapability: AgentWatchLiveActivityPushCapability = .system,
        tokenSink: (any AgentWatchLiveActivityPushTokenSinking)? = FirestoreAgentWatchLiveActivityPushTokenSink()
    ) {
        self.backend = backend
        self.pushCapability = pushCapability
        self.tokenSink = tokenSink
        backend.setPushTokenHandler { [weak self] hex in
            self?.handleReceivedPushToken(hex)
        }
    }

    func start(sessionId: String, startedAt: Date) {
        if backend.activeSessionId == sessionId { return }
        let initialState = makeState(
            appName: "Agent Live",
            lastAction: "Watching Mac",
            actionsCount: 0,
            approvalPending: false,
            elapsed: 0,
            remoteRefreshEnabled: false
        )
        let preferred: AgentWatchLiveActivityPushType = pushCapability.canRequestTokenPush ? .token : .none
        do {
            try request(sessionId: sessionId, startedAt: startedAt, initialState: initialState, pushType: preferred)
            return
        } catch {
            Self.log.warning("start: Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            if preferred != .token {
                end()
                return
            }
        }
        do {
            try request(sessionId: sessionId, startedAt: startedAt, initialState: initialState, pushType: .none)
        } catch {
            Self.log.warning("start: Live Activity fallback request failed: \(error.localizedDescription, privacy: .public)")
            end()
        }
    }

    func update(
        appName: String,
        lastAction: String,
        actionsCount: Int,
        approvalPending: Bool,
        elapsed: TimeInterval,
        pendingApprovalId: String? = nil
    ) {
        let state = makeState(
            appName: appName,
            lastAction: lastAction,
            actionsCount: actionsCount,
            approvalPending: approvalPending,
            elapsed: elapsed,
            remoteRefreshEnabled: hasPushToken,
            pendingApprovalId: pendingApprovalId
        )
        lastState = state
        backend.update(state)
    }

    func end() {
        lastState = nil
        appliedPushType = .none
        backend.end()
    }

    private func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState,
        pushType: AgentWatchLiveActivityPushType
    ) throws {
        lastState = initialState
        appliedPushType = pushType
        try backend.request(
            sessionId: sessionId,
            startedAt: startedAt,
            initialState: initialState,
            pushType: pushType
        )
    }

    private func makeState(
        appName: String,
        lastAction: String,
        actionsCount: Int,
        approvalPending: Bool,
        elapsed: TimeInterval,
        remoteRefreshEnabled: Bool,
        pendingApprovalId: String? = nil
    ) -> AgentWatchLiveActivityAttributes.ContentState {
        AgentWatchLiveActivityAttributes.ContentState(
            appName: appName,
            lastAction: lastAction,
            actionsCount: actionsCount,
            approvalPending: approvalPending,
            elapsed: elapsed,
            remoteRefreshEnabled: remoteRefreshEnabled,
            pendingApprovalId: pendingApprovalId
        )
    }

    private func handleReceivedPushToken(_ hex: String) {
        guard appliedPushType == .token, !hex.isEmpty else { return }
        if var state = lastState {
            state.remoteRefreshEnabled = true
            lastState = state
            backend.update(state)
        }
        guard let sessionId = backend.activeSessionId, !sessionId.isEmpty else { return }
        let sink = tokenSink
        Task { await sink?.persist(sessionId: sessionId, tokenHex: hex) }
    }
}

@available(iOS 16.1, *)
@MainActor
protocol AgentWatchLiveActivityBackend: AnyObject {
    var activeSessionId: String? { get }
    func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState,
        pushType: AgentWatchLiveActivityPushType
    ) throws
    func update(_ state: AgentWatchLiveActivityAttributes.ContentState)
    func end()
    func setPushTokenHandler(_ handler: (@MainActor (String) -> Void)?)
}

@available(iOS 16.1, *)
@MainActor
private final class ActivityKitAgentWatchLiveActivityBackend: AgentWatchLiveActivityBackend {
    private var activity: Activity<AgentWatchLiveActivityAttributes>?
    private var pushTokenTask: Task<Void, Never>?
    private var pushTokenHandler: (@MainActor (String) -> Void)?

    var activeSessionId: String? { activity?.attributes.sessionId }

    func setPushTokenHandler(_ handler: (@MainActor (String) -> Void)?) {
        pushTokenHandler = handler
    }

    func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState,
        pushType: AgentWatchLiveActivityPushType
    ) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = AgentWatchLiveActivityAttributes(
            sessionId: sessionId,
            startedAt: startedAt
        )
        let content = ActivityContent(state: initialState, staleDate: nil)
        activity = try Activity.request(
            attributes: attributes,
            content: content,
            pushType: Self.activityKitPushType(pushType)
        )
        if let activity {
            observePushToken(activity)
        }
    }

    private static func activityKitPushType(_ pushType: AgentWatchLiveActivityPushType) -> PushType? {
        if #available(iOS 16.2, *), pushType == .token {
            return .token
        }
        return nil
    }

    func update(_ state: AgentWatchLiveActivityAttributes.ContentState) {
        guard let activity else { return }
        Task.detached { [activity, state] in
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        pushTokenTask?.cancel()
        pushTokenTask = nil
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .default)
        }
    }

    private func observePushToken(_ activity: Activity<AgentWatchLiveActivityAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    self?.pushTokenHandler?(hex)
                }
            }
        }
    }
}

@MainActor
final class FirestoreAgentWatchLiveActivityPushTokenSink: AgentWatchLiveActivityPushTokenSinking {
    private static let log = Logger(
        subsystem: "com.openburnbar.app",
        category: "AgentWatchLiveActivityPushToken"
    )

    func persist(sessionId: String, tokenHex: String) async {
        guard !sessionId.isEmpty, !tokenHex.isEmpty else { return }
        do {
            try await MobileDeviceIdentity.mergeDevicePushFields([
                "liveActivityPushToken": tokenHex,
                "liveActivitySessionId": sessionId
            ])
        } catch {
            Self.log.warning(
                "persist: Live Activity push token write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

@MainActor
final class AgentWatchLiveActivityManagerStub {
    static let shared = AgentWatchLiveActivityManagerStub()

    var hasActiveActivity: Bool { false }
    func start(sessionId: String, startedAt: Date) {}
    func update(appName: String, lastAction: String, actionsCount: Int, approvalPending: Bool, elapsed: TimeInterval, pendingApprovalId: String? = nil) {}
    func end() {}
}
#endif
