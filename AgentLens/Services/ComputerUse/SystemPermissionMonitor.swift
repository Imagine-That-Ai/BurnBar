#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import OSLog
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Phase 14 — Central macOS TCC monitor. Polls the six system
/// permission buckets the System Permission Concierge cares about and
/// emits structured status frames over the live Computer Use control
/// stream every time a bucket flips.
///
/// The monitor is intentionally lazy: it does *not* fan-out frames on
/// its 5 s tick unless a status changed. The chat surface only paints a
/// pill when a tool failure binds a status to an originating tool call,
/// or when an explicit grant request is in flight.
@MainActor
public final class SystemPermissionMonitor {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "SystemPermissionConcierge")

    public typealias FrameSink = @MainActor @Sendable (HermesRealtimeRelayFrame) async -> Void
    public typealias UidProvider = @MainActor @Sendable () -> (uid: String, connectionId: String, sessionId: String?)?

    public struct Snapshot: Equatable, Sendable {
        public let kind: SystemPermissionKind
        public let bundleId: String?
        public let status: SystemPermissionStatus
        public let lastChangedAt: Date

        public init(
            kind: SystemPermissionKind,
            bundleId: String? = nil,
            status: SystemPermissionStatus,
            lastChangedAt: Date = Date()
        ) {
            self.kind = kind
            self.bundleId = bundleId
            self.status = status
            self.lastChangedAt = lastChangedAt
        }

        fileprivate var key: String { "\(kind.rawValue)|\(bundleId ?? "")" }
    }

    public static let shared = SystemPermissionMonitor()

    public private(set) var snapshots: [String: Snapshot] = [:]
    public private(set) var pendingToolCallByKey: [String: PendingTool] = [:]

    public struct PendingTool: Sendable {
        public let toolCallId: String
        public let toolName: String?
        public let category: String?
        public let recordedAt: Date

        public init(toolCallId: String, toolName: String?, category: String?, recordedAt: Date = Date()) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.category = category
            self.recordedAt = recordedAt
        }
    }

    private var pollTask: Task<Void, Never>?
    private var becomeActiveObserver: NSObjectProtocol?
    private var bundleIdsToAudit: Set<String> = []

    private var frameSink: FrameSink?
    private var uidProvider: UidProvider?

    public init() {}

    public func attach(frameSink: @escaping FrameSink, uidProvider: @escaping UidProvider) {
        self.frameSink = frameSink
        self.uidProvider = uidProvider
        Task { @MainActor in await refreshAll(emitting: false) }
    }

    public func detach() {
        frameSink = nil
        uidProvider = nil
    }

    public func start(pollInterval: TimeInterval = 5.0) {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            await self?.refreshAll(emitting: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refreshAll(emitting: true)
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll(emitting: true) }
        }
        Self.log.info("system_permission_monitor_started interval=\(pollInterval, privacy: .public)")
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            becomeActiveObserver = nil
        }
        Self.log.info("system_permission_monitor_stopped")
    }

    /// Register a bundle id whose Automation status should be polled on
    /// every tick. Called by the receiver whenever a phone request
    /// targets an Automation bundle, and by the failure classifier
    /// whenever a tool error carries a bundle id.
    public func trackAutomation(bundleId: String) {
        guard !bundleId.isEmpty else { return }
        bundleIdsToAudit.insert(bundleId)
    }

    /// Bind an originating tool call to a TCC bucket so the granted
    /// transition can be paired back with the failed call for retry.
    public func registerPendingTool(
        toolCallId: String,
        toolName: String?,
        category: String?,
        kind: SystemPermissionKind,
        bundleId: String? = nil
    ) {
        let key = "\(kind.rawValue)|\(bundleId ?? "")"
        pendingToolCallByKey[key] = PendingTool(
            toolCallId: toolCallId,
            toolName: toolName,
            category: category
        )
    }

    public func clearPendingTool(for kind: SystemPermissionKind, bundleId: String? = nil) {
        let key = "\(kind.rawValue)|\(bundleId ?? "")"
        pendingToolCallByKey.removeValue(forKey: key)
    }

    /// Optimistic emit: the receiver just took an action on this kind
    /// and wants the iOS sheet to flip into the "requesting" state
    /// before the monitor's poll catches the actual TCC change. The
    /// snapshot is not promoted to `granted` here — only the live
    /// status poll can do that.
    public func emitRequesting(
        kind: SystemPermissionKind,
        bundleId: String? = nil,
        originatingToolCallId: String?,
        originatingToolName: String?,
        instructions: String?,
        failureCategory: String?
    ) async {
        let snapshot = Snapshot(kind: kind, bundleId: bundleId, status: .requesting)
        snapshots[snapshot.key] = snapshot
        await emit(snapshot,
                   originatingToolCallId: originatingToolCallId,
                   originatingToolName: originatingToolName,
                   instructions: instructions,
                   failureCategory: failureCategory)
    }

    /// Tool failure ingestion path. Called by `SystemPermissionToolFailureWatcher`
    /// when a Hermes / CLI tool result string matches a TCC fingerprint.
    public func ingestClassified(
        match: SystemPermissionToolFailureClassifier.Match,
        toolCallId: String,
        toolName: String?
    ) async {
        registerPendingTool(
            toolCallId: toolCallId,
            toolName: toolName,
            category: match.category,
            kind: match.kind,
            bundleId: match.bundleId
        )
        if let bundleId = match.bundleId { trackAutomation(bundleId: bundleId) }
        let snapshot = Snapshot(kind: match.kind, bundleId: match.bundleId, status: .needsAccess)
        snapshots[snapshot.key] = snapshot
        await emit(
            snapshot,
            originatingToolCallId: toolCallId,
            originatingToolName: toolName,
            instructions: nil,
            failureCategory: match.category
        )
    }

    // MARK: - TCC polling

    private func refreshAll(emitting: Bool) async {
        await checkBucket(kind: .screenRecording, status: readScreenRecordingStatus(), emitting: emitting)
        await checkBucket(kind: .accessibility, status: readAccessibilityStatus(), emitting: emitting)
        await checkBucket(kind: .camera, status: readCameraStatus(), emitting: emitting)
        await checkBucket(kind: .microphone, status: readMicrophoneStatus(), emitting: emitting)
        await checkBucket(kind: .fullDiskAccess, status: readFullDiskAccessStatus(), emitting: emitting)
        for bundleId in bundleIdsToAudit {
            await checkBucket(
                kind: .automation,
                bundleId: bundleId,
                status: readAutomationStatus(forBundleId: bundleId),
                emitting: emitting
            )
        }
    }

    private func checkBucket(
        kind: SystemPermissionKind,
        bundleId: String? = nil,
        status: SystemPermissionStatus,
        emitting: Bool
    ) async {
        let key = "\(kind.rawValue)|\(bundleId ?? "")"
        let existing = snapshots[key]
        if existing?.status == status { return }
        let snapshot = Snapshot(kind: kind, bundleId: bundleId, status: status)
        snapshots[key] = snapshot
        guard emitting else { return }
        let pending = pendingToolCallByKey[key]
        await emit(
            snapshot,
            originatingToolCallId: pending?.toolCallId,
            originatingToolName: pending?.toolName,
            instructions: nil,
            failureCategory: pending?.category
        )
        if status == .granted, pending != nil {
            // Retain the pending tool record so the
            // `SystemPermissionRetryDispatcher` can resolve it on the
            // same tick. The dispatcher clears it after retry.
        }
    }

    private func emit(
        _ snapshot: Snapshot,
        originatingToolCallId: String?,
        originatingToolName: String?,
        instructions: String?,
        failureCategory: String?
    ) async {
        guard let frameSink, let provider = uidProvider, let identity = provider() else { return }
        let wireStatus = HermesRealtimeRelaySystemPermissionStatus(
            kind: snapshot.kind.wire,
            bundleId: snapshot.bundleId,
            status: snapshot.status.wire,
            originatingToolCallId: originatingToolCallId,
            originatingToolName: originatingToolName,
            deepLink: snapshot.kind.systemSettingsDeepLink,
            instructions: instructions,
            failureCategory: failureCategory,
            lastChangedAt: snapshot.lastChangedAt
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlSystemPermissionStatus,
            uid: identity.uid,
            connectionId: identity.connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.system.permission",
                sessionId: identity.sessionId,
                systemPermissionStatus: wireStatus
            )
        )
        await frameSink(frame)
        Self.log.info("system_permission_emit kind=\(snapshot.kind.rawValue, privacy: .public) status=\(snapshot.status.rawValue, privacy: .public)")
    }

    // MARK: - TCC readers

    private func readScreenRecordingStatus() -> SystemPermissionStatus {
        #if canImport(CoreGraphics)
        return CGPreflightScreenCaptureAccess() ? .granted : .needsAccess
        #else
        return .unknown
        #endif
    }

    private func readAccessibilityStatus() -> SystemPermissionStatus {
        AXIsProcessTrusted() ? .granted : .needsAccess
    }

    private func readCameraStatus() -> SystemPermissionStatus {
        avStatus(for: .video)
    }

    private func readMicrophoneStatus() -> SystemPermissionStatus {
        avStatus(for: .audio)
    }

    private func avStatus(for mediaType: AVMediaType) -> SystemPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .needsAccess
        @unknown default: return .unknown
        }
    }

    /// Probe-read against a deliberately small set of FDA-protected
    /// paths. macOS returns `Operation not permitted` (EPERM) when the
    /// caller lacks Full Disk Access. We treat a successful read as
    /// granted, EPERM as needsAccess, and any other error as unknown.
    private func readFullDiskAccessStatus() -> SystemPermissionStatus {
        let probePaths = [
            ("\(NSHomeDirectory())/Library/Safari/Bookmarks.plist"),
            ("\(NSHomeDirectory())/Library/Mail")
        ]
        for path in probePaths {
            let url = URL(fileURLWithPath: path)
            do {
                _ = try url.resourceValues(forKeys: [.isReadableKey])
                if FileManager.default.isReadableFile(atPath: path) {
                    return .granted
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == EPERM {
                    return .needsAccess
                }
            }
        }
        // Conservative: most users have at least Mail or Safari, so
        // missing both points to FDA being unset rather than granted.
        return .needsAccess
    }

    /// Best-effort Automation status read. macOS 10.14+ ships
    /// `AEDeterminePermissionToAutomateTarget` which surfaces the
    /// Automation prompt when `askUserIfNeeded` is true; we call it
    /// with `false` so polling never opens a dialog. Returns
    /// `.granted` when the call succeeds, `.needsAccess` for
    /// errAEEventNotPermitted, `.denied` for procNotFound style
    /// errors, and `.unknown` for everything else.
    private func readAutomationStatus(forBundleId bundleId: String) -> SystemPermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            typeWildCard,
            typeWildCard,
            false
        )
        switch status {
        case noErr: return .granted
        case OSStatus(-1744):   // errAEEventNotPermitted
            return .needsAccess
        case OSStatus(-1743):   // errAEEventNotAuthorized
            return .denied
        case OSStatus(procNotFound): return .unknown
        default: return .unknown
        }
    }
}
#endif
