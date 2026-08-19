import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarKernel

/// Durable daemon-side rendezvous between agent tool execution and Safari's
/// short-lived native-message handler.
///
/// The WebExtension attaches a leased session and polls for one command at a
/// time. Agent execution enqueues a command and suspends until the exact
/// command is completed, cancelled, detached, or timed out. The broker owns
/// tab authority and freshness; the extension never gets to broaden either by
/// merely reporting more tabs.
public actor BurnBarSafariSessionBroker {
    public struct Configuration: Sendable, Equatable {
        public var leaseDuration: TimeInterval
        public var maximumQueuedCommands: Int
        public var maximumCommandTimeoutMillis: Int
        public var maximumArgumentBytes: Int
        public var idlePollAfterMillis: Int

        public init(
            leaseDuration: TimeInterval = 15,
            maximumQueuedCommands: Int = 16,
            maximumCommandTimeoutMillis: Int = 120_000,
            maximumArgumentBytes: Int = 48 * 1024,
            idlePollAfterMillis: Int = 200
        ) {
            self.leaseDuration = max(2, leaseDuration)
            self.maximumQueuedCommands = max(1, maximumQueuedCommands)
            self.maximumCommandTimeoutMillis = max(1_000, maximumCommandTimeoutMillis)
            self.maximumArgumentBytes = max(1_024, maximumArgumentBytes)
            self.idlePollAfterMillis = max(50, idlePollAfterMillis)
        }
    }

    public enum BrokerError: Error, LocalizedError, Sendable, Equatable {
        case incompatibleProtocol
        case invalidAttachRequest
        case unknownSession
        case leaseExpired
        case queueFull
        case commandAlreadyInFlight
        case commandExpired
        case commandCancelled
        case commandNotFound
        case commandMismatch
        case inactiveTargetTab
        case unownedTargetTab(Int)
        case staleNavigationEpoch(expected: Int, actual: Int)
        case payloadTooLarge(actual: Int, maximum: Int)
        case invalidPageState
        case invalidOpenTabResult

        public var errorDescription: String? {
            switch self {
            case .incompatibleProtocol:
                return "The Safari extension and daemon do not share a supported protocol version."
            case .invalidAttachRequest:
                return "The Safari extension attach request is malformed."
            case .unknownSession:
                return "The Safari extension session is not attached."
            case .leaseExpired:
                return "The Safari extension session lease expired."
            case .queueFull:
                return "The Safari command queue is full."
            case .commandAlreadyInFlight:
                return "A Safari command is already in flight for this session."
            case .commandExpired:
                return "The Safari command expired before it completed."
            case .commandCancelled:
                return "The Safari command was cancelled."
            case .commandNotFound:
                return "The Safari command is no longer pending."
            case .commandMismatch:
                return "The Safari completion does not match the command that was delivered."
            case .inactiveTargetTab:
                return "Safari actions may only target the active handed-off tab."
            case .unownedTargetTab(let tabID):
                return "Safari tab \(tabID) is not owned by this agent session."
            case .staleNavigationEpoch(let expected, let actual):
                return "The Safari command was created for navigation epoch \(expected), but the tab is now at epoch \(actual)."
            case .payloadTooLarge(let actual, let maximum):
                return "The Safari command payload is \(actual) bytes; the maximum inline command payload is \(maximum) bytes."
            case .invalidPageState:
                return "The Safari extension reported an invalid or non-top-frame page state."
            case .invalidOpenTabResult:
                return "Safari did not return one unambiguous newly opened tab matching the completion."
            }
        }
    }

    private struct PendingCommand {
        let command: BurnBarSafariCommand
        let continuation: CheckedContinuation<BurnBarSafariCommandCompletionRequest, Error>
        var delivered = false
    }

    private struct Session {
        let sessionID: String
        let extensionInstanceID: String
        let clientName: String
        let protocolVersion: Int
        let capabilities: BurnBarSafariExtensionCapabilities
        var leaseExpiresAt: Date
        var activePage: BurnBarSafariPageState?
        var tabs: [Int: BurnBarSafariTabSnapshot]
        var ownedTabIDs: Set<Int>
        var queue: [String]
        var pending: [String: PendingCommand]
        var inFlightCommandID: String?
    }

    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var sessions: [String: Session] = [:]
    private var sessionIDByExtensionInstanceID: [String: String] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    public init(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
    }

    public func attach(
        _ request: BurnBarSafariSessionAttachRequest
    ) throws -> BurnBarSafariSessionAttachResponse {
        try pruneExpiredSessions()
        let extensionID = request.extensionInstanceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientName = request.clientName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard extensionID.isEmpty == false,
              extensionID.utf8.count <= 256,
              clientName.isEmpty == false,
              clientName.utf8.count <= 256 else {
            throw BrokerError.invalidAttachRequest
        }
        guard request.supportedProtocolVersions.contains(BurnBarSafariProtocol.currentVersion) else {
            throw BrokerError.incompatibleProtocol
        }
        if let previousSessionID = sessionIDByExtensionInstanceID[extensionID] {
            finishSession(
                previousSessionID,
                error: BrokerError.commandCancelled
            )
        }

        let sessionID = UUID().uuidString.lowercased()
        let leaseExpiresAt = now().addingTimeInterval(configuration.leaseDuration)
        var tabs: [Int: BurnBarSafariTabSnapshot] = [:]
        var ownedTabIDs = Set<Int>()
        if let activePage = request.activePage {
            try Self.validate(pageState: activePage)
            guard activePage.isActive else { throw BrokerError.inactiveTargetTab }
            ownedTabIDs.insert(activePage.tabId)
            tabs[activePage.tabId] = BurnBarSafariTabSnapshot(
                tabId: activePage.tabId,
                windowId: activePage.windowId,
                url: activePage.url,
                title: activePage.title,
                isActive: true,
                isOwned: true,
                navigationEpoch: activePage.navigationEpoch
            )
        }
        sessions[sessionID] = Session(
            sessionID: sessionID,
            extensionInstanceID: extensionID,
            clientName: clientName,
            protocolVersion: BurnBarSafariProtocol.currentVersion,
            capabilities: request.capabilities,
            leaseExpiresAt: leaseExpiresAt,
            activePage: request.activePage,
            tabs: tabs,
            ownedTabIDs: ownedTabIDs,
            queue: [],
            pending: [:],
            inFlightCommandID: nil
        )
        sessionIDByExtensionInstanceID[extensionID] = sessionID
        return BurnBarSafariSessionAttachResponse(
            sessionId: sessionID,
            protocolVersion: BurnBarSafariProtocol.currentVersion,
            leaseExpiresAt: leaseExpiresAt,
            pollAfterMillis: configuration.idlePollAfterMillis
        )
    }

    public func detach(
        _ request: BurnBarSafariSessionDetachRequest
    ) -> BurnBarSafariCommandCompletionResponse {
        let accepted = sessions[request.sessionId] != nil
        finishSession(request.sessionId, error: BrokerError.commandCancelled)
        return BurnBarSafariCommandCompletionResponse(accepted: accepted)
    }

    public func status(sessionID: String) throws -> BurnBarSafariSessionStatusResponse {
        try pruneExpiredSessions()
        guard let session = sessions[sessionID] else {
            return BurnBarSafariSessionStatusResponse(
                sessionId: sessionID,
                attached: false
            )
        }
        return BurnBarSafariSessionStatusResponse(
            sessionId: sessionID,
            attached: true,
            leaseExpiresAt: session.leaseExpiresAt,
            activePage: session.activePage,
            ownedTabIds: session.ownedTabIDs.sorted()
        )
    }

    public func activePage(sessionID: String) throws -> BurnBarSafariPageState {
        try pruneExpiredSessions()
        guard let session = sessions[sessionID] else { throw BrokerError.unknownSession }
        guard let page = session.activePage else { throw BrokerError.invalidPageState }
        try Self.validate(pageState: page)
        guard page.isActive else { throw BrokerError.inactiveTargetTab }
        guard session.ownedTabIDs.contains(page.tabId) else {
            throw BrokerError.unownedTargetTab(page.tabId)
        }
        return page
    }

    public func poll(
        _ request: BurnBarSafariCommandPollRequest
    ) throws -> BurnBarSafariCommandPollResponse {
        try pruneExpiredSessions()
        guard var session = sessions[request.sessionId] else {
            throw BrokerError.unknownSession
        }
        try updateReportedState(
            activePage: request.activePage,
            knownTabs: request.knownTabs,
            session: &session
        )
        session.leaseExpiresAt = now().addingTimeInterval(configuration.leaseDuration)

        if let inFlightID = session.inFlightCommandID,
           let pending = session.pending[inFlightID] {
            sessions[request.sessionId] = session
            return BurnBarSafariCommandPollResponse(
                command: pending.command,
                leaseExpiresAt: session.leaseExpiresAt,
                pollAfterMillis: 0
            )
        }

        while let commandID = session.queue.first {
            session.queue.removeFirst()
            guard var pending = session.pending[commandID] else { continue }
            if pending.command.expiresAt <= now() {
                session.pending.removeValue(forKey: commandID)
                timeoutTasks.removeValue(forKey: commandID)?.cancel()
                pending.continuation.resume(throwing: BrokerError.commandExpired)
                continue
            }
            do {
                try validateTarget(for: pending.command, in: session)
            } catch {
                session.pending.removeValue(forKey: commandID)
                timeoutTasks.removeValue(forKey: commandID)?.cancel()
                pending.continuation.resume(throwing: error)
                continue
            }
            pending.delivered = true
            session.pending[commandID] = pending
            session.inFlightCommandID = commandID
            sessions[request.sessionId] = session
            return BurnBarSafariCommandPollResponse(
                command: pending.command,
                leaseExpiresAt: session.leaseExpiresAt,
                pollAfterMillis: 0
            )
        }

        sessions[request.sessionId] = session
        return BurnBarSafariCommandPollResponse(
            command: nil,
            leaseExpiresAt: session.leaseExpiresAt,
            pollAfterMillis: configuration.idlePollAfterMillis
        )
    }

    public func complete(
        _ request: BurnBarSafariCommandCompletionRequest
    ) throws -> BurnBarSafariCommandCompletionResponse {
        try pruneExpiredSessions()
        guard var session = sessions[request.sessionId] else {
            throw BrokerError.unknownSession
        }
        guard session.inFlightCommandID == request.commandId,
              let pending = session.pending[request.commandId],
              pending.delivered else {
            throw BrokerError.commandMismatch
        }
        guard pending.command.expiresAt > now() else {
            session.pending.removeValue(forKey: request.commandId)
            session.inFlightCommandID = nil
            sessions[request.sessionId] = session
            timeoutTasks.removeValue(forKey: request.commandId)?.cancel()
            pending.continuation.resume(throwing: BrokerError.commandExpired)
            throw BrokerError.commandExpired
        }

        try Self.validate(pageState: request.pageState)
        let permitsUnownedActivePage: Bool
        switch pending.command.action {
        case .openTab where request.ok:
            let openedTab = try Self.validatedOpenedTab(
                for: pending.command,
                completion: request,
                session: session
            )
            session.ownedTabIDs.insert(openedTab.tabId)
            permitsUnownedActivePage = true
        case .closeTab where request.ok:
            permitsUnownedActivePage = true
        default:
            permitsUnownedActivePage = false
        }
        let reportedActivePage: BurnBarSafariPageState?
        if permitsUnownedActivePage,
           session.ownedTabIDs.contains(request.pageState.tabId) == false {
            // Opening or closing a tab can race with a user selecting another
            // tab. Record the inventory without silently claiming that active
            // user-controlled tab.
            session.activePage = nil
            reportedActivePage = nil
        } else {
            reportedActivePage = request.pageState
        }
        try updateReportedState(
            activePage: reportedActivePage,
            knownTabs: request.tabs,
            session: &session
        )
        applyOwnershipTransition(
            for: pending.command,
            completion: request,
            session: &session
        )
        session.leaseExpiresAt = now().addingTimeInterval(configuration.leaseDuration)
        session.pending.removeValue(forKey: request.commandId)
        session.inFlightCommandID = nil
        sessions[request.sessionId] = session
        timeoutTasks.removeValue(forKey: request.commandId)?.cancel()
        pending.continuation.resume(returning: request)
        return BurnBarSafariCommandCompletionResponse(accepted: true)
    }

    public func execute(
        action: SafariActionDescriptor
    ) async throws -> BurnBarSafariToolResponse {
        try pruneExpiredSessions()
        guard let session = sessions[action.safariSessionId] else {
            throw BrokerError.unknownSession
        }
        guard session.queue.count + session.pending.count < configuration.maximumQueuedCommands else {
            throw BrokerError.queueFull
        }
        guard session.inFlightCommandID == nil, session.pending.isEmpty else {
            throw BrokerError.commandAlreadyInFlight
        }

        let arguments = Self.arguments(for: action)
        let argumentBytes = try JSONEncoder().encode(arguments).count
        guard argumentBytes <= configuration.maximumArgumentBytes else {
            throw BrokerError.payloadTooLarge(
                actual: argumentBytes,
                maximum: configuration.maximumArgumentBytes
            )
        }
        let timeoutMillis = min(
            max(1_000, action.timeoutMillis),
            configuration.maximumCommandTimeoutMillis
        )
        let issuedAt = now()
        let command = BurnBarSafariCommand(
            sessionId: action.safariSessionId,
            action: action.kind,
            arguments: arguments,
            targetTabId: action.tabId ?? defaultTargetTab(for: action.kind, session: session),
            expectedNavigationEpoch: action.expectedNavigationEpoch,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(Double(timeoutMillis) / 1_000)
        )

        let completion: BurnBarSafariCommandCompletionRequest = try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard Task.isCancelled == false else {
                        continuation.resume(throwing: BrokerError.commandCancelled)
                        return
                    }
                    guard var current = sessions[action.safariSessionId] else {
                        continuation.resume(throwing: BrokerError.unknownSession)
                        return
                    }
                    current.queue.append(command.commandId)
                    current.pending[command.commandId] = PendingCommand(
                        command: command,
                        continuation: continuation
                    )
                    sessions[action.safariSessionId] = current
                    timeoutTasks[command.commandId] = Task { [weak self] in
                        guard let self else { return }
                        let delay = max(
                            0,
                            command.expiresAt.timeIntervalSince(await self.currentTime())
                        )
                        try? await Task.sleep(for: .seconds(delay))
                        guard Task.isCancelled == false else { return }
                        await self.expireCommand(
                            sessionID: action.safariSessionId,
                            commandID: command.commandId
                        )
                    }
                }
            },
            onCancel: {
                Task {
                    await self.cancelCommand(
                        sessionID: action.safariSessionId,
                        commandID: command.commandId
                    )
                }
            }
        )

        return BurnBarSafariToolResponse(
            ok: completion.ok,
            result: completion.result,
            error: completion.error,
            pageState: completion.pageState
        )
    }

    public func abort(sessionID: String) {
        finishSession(sessionID, error: BrokerError.commandCancelled)
    }

    private func updateReportedState(
        activePage: BurnBarSafariPageState?,
        knownTabs: [BurnBarSafariTabSnapshot],
        session: inout Session
    ) throws {
        var reported: [Int: BurnBarSafariTabSnapshot] = [:]
        for tab in knownTabs {
            guard tab.tabId >= 0, tab.navigationEpoch >= 0 else {
                throw BrokerError.invalidPageState
            }
            reported[tab.tabId] = BurnBarSafariTabSnapshot(
                tabId: tab.tabId,
                windowId: tab.windowId,
                url: tab.url,
                title: tab.title,
                isActive: tab.isActive,
                isOwned: session.ownedTabIDs.contains(tab.tabId),
                navigationEpoch: tab.navigationEpoch
            )
        }
        if let activePage {
            try Self.validate(pageState: activePage)
            guard activePage.isActive else { throw BrokerError.inactiveTargetTab }
            // A poll may refresh the handed-off tab, but it may not silently
            // claim a different tab while a run is active.
            guard session.ownedTabIDs.contains(activePage.tabId) else {
                throw BrokerError.unownedTargetTab(activePage.tabId)
            }
            session.activePage = activePage
            reported[activePage.tabId] = BurnBarSafariTabSnapshot(
                tabId: activePage.tabId,
                windowId: activePage.windowId,
                url: activePage.url,
                title: activePage.title,
                isActive: true,
                isOwned: true,
                navigationEpoch: activePage.navigationEpoch
            )
        }
        if reported.isEmpty == false {
            session.tabs = reported
        }
    }

    private func validateTarget(
        for command: BurnBarSafariCommand,
        in session: Session
    ) throws {
        guard command.expiresAt > now() else { throw BrokerError.commandExpired }
        switch command.action {
        case .openTab, .listTabs, .abort:
            return
        default:
            break
        }
        guard let tabID = command.targetTabId else {
            throw BrokerError.invalidPageState
        }
        guard session.ownedTabIDs.contains(tabID) else {
            throw BrokerError.unownedTargetTab(tabID)
        }
        guard let activePage = session.activePage,
              activePage.tabId == tabID,
              activePage.isActive else {
            throw BrokerError.inactiveTargetTab
        }
        if let expected = command.expectedNavigationEpoch,
           expected != activePage.navigationEpoch {
            throw BrokerError.staleNavigationEpoch(
                expected: expected,
                actual: activePage.navigationEpoch
            )
        }
    }

    private func applyOwnershipTransition(
        for command: BurnBarSafariCommand,
        completion: BurnBarSafariCommandCompletionRequest,
        session: inout Session
    ) {
        switch command.action {
        case .closeTab where completion.ok:
            if let tabID = command.targetTabId {
                session.ownedTabIDs.remove(tabID)
                session.tabs.removeValue(forKey: tabID)
                if session.activePage?.tabId == tabID {
                    session.activePage = nil
                }
            }
        default:
            break
        }
        session.tabs = session.tabs.mapValues { tab in
            BurnBarSafariTabSnapshot(
                tabId: tab.tabId,
                windowId: tab.windowId,
                url: tab.url,
                title: tab.title,
                isActive: tab.isActive,
                isOwned: session.ownedTabIDs.contains(tab.tabId),
                navigationEpoch: tab.navigationEpoch
            )
        }
    }

    private static func validatedOpenedTab(
        for command: BurnBarSafariCommand,
        completion: BurnBarSafariCommandCompletionRequest,
        session: Session
    ) throws -> BurnBarSafariTabSnapshot {
        guard command.action == .openTab,
              completion.ok,
              let result = completion.result else {
            throw BrokerError.invalidOpenTabResult
        }
        let opened: BurnBarSafariTabSnapshot
        do {
            let data = try JSONEncoder().encode(result)
            opened = try JSONDecoder().decode(BurnBarSafariTabSnapshot.self, from: data)
        } catch {
            throw BrokerError.invalidOpenTabResult
        }
        try validate(tabSnapshot: opened)
        guard opened.isActive,
              opened.isOwned,
              session.ownedTabIDs.contains(opened.tabId) == false,
              session.tabs[opened.tabId] == nil else {
            throw BrokerError.invalidOpenTabResult
        }

        let reportedMatches = completion.tabs.filter { $0.tabId == opened.tabId }
        guard reportedMatches.count == 1,
              let reported = reportedMatches.first else {
            throw BrokerError.invalidOpenTabResult
        }
        try validate(tabSnapshot: reported)
        guard reported.isOwned,
              reported.windowId == opened.windowId else {
            throw BrokerError.invalidOpenTabResult
        }
        if completion.pageState.tabId == opened.tabId {
            guard completion.pageState.windowId == opened.windowId else {
                throw BrokerError.invalidOpenTabResult
            }
        }
        return opened
    }

    private func defaultTargetTab(
        for action: BurnBarSafariActionKind,
        session: Session
    ) -> Int? {
        switch action {
        case .openTab, .listTabs, .abort:
            return nil
        default:
            return session.activePage?.tabId
        }
    }

    private func expireCommand(sessionID: String, commandID: String) {
        failCommand(
            sessionID: sessionID,
            commandID: commandID,
            error: BrokerError.commandExpired
        )
    }

    private func cancelCommand(sessionID: String, commandID: String) {
        failCommand(
            sessionID: sessionID,
            commandID: commandID,
            error: BrokerError.commandCancelled
        )
    }

    private func failCommand(sessionID: String, commandID: String, error: Error) {
        guard var session = sessions[sessionID],
              let pending = session.pending.removeValue(forKey: commandID) else {
            timeoutTasks.removeValue(forKey: commandID)?.cancel()
            return
        }
        session.queue.removeAll { $0 == commandID }
        if session.inFlightCommandID == commandID {
            session.inFlightCommandID = nil
        }
        sessions[sessionID] = session
        timeoutTasks.removeValue(forKey: commandID)?.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func currentTime() -> Date {
        now()
    }

    private func pruneExpiredSessions() throws {
        let current = now()
        let expired = sessions.compactMap { id, session in
            session.leaseExpiresAt <= current ? id : nil
        }
        for sessionID in expired {
            finishSession(sessionID, error: BrokerError.leaseExpired)
        }
    }

    private func finishSession(_ sessionID: String, error: Error) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        if sessionIDByExtensionInstanceID[session.extensionInstanceID] == sessionID {
            sessionIDByExtensionInstanceID.removeValue(forKey: session.extensionInstanceID)
        }
        for (commandID, pending) in session.pending {
            timeoutTasks.removeValue(forKey: commandID)?.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private static func validate(pageState: BurnBarSafariPageState) throws {
        guard pageState.tabId >= 0,
              pageState.navigationEpoch >= 0,
              pageState.isTopFrame,
              pageState.url.utf8.count <= 16 * 1024,
              pageState.title.utf8.count <= 8 * 1024 else {
            throw BrokerError.invalidPageState
        }
    }

    private static func validate(tabSnapshot: BurnBarSafariTabSnapshot) throws {
        guard tabSnapshot.tabId >= 0,
              tabSnapshot.windowId.map({ $0 >= 0 }) ?? true,
              tabSnapshot.navigationEpoch >= 0,
              tabSnapshot.url.utf8.count <= 16 * 1024,
              tabSnapshot.title.utf8.count <= 8 * 1024 else {
            throw BrokerError.invalidOpenTabResult
        }
    }

    private static func arguments(
        for action: SafariActionDescriptor
    ) -> BurnBarJSONValue {
        var object: [String: BurnBarJSONValue] = [
            "timeoutMillis": .number(Double(action.timeoutMillis))
        ]
        if let tabID = action.tabId { object["tabId"] = .number(Double(tabID)) }
        if let expected = action.expectedNavigationEpoch {
            object["expectedNavigationEpoch"] = .number(Double(expected))
        }
        if let selector = action.selector { object["selector"] = .string(selector) }
        if let text = action.text { object["text"] = .string(text) }
        if let url = action.url { object["url"] = .string(url) }
        if let operation = action.navigationOperation {
            object["operation"] = .string(operation.rawValue)
        }
        if let key = action.key { object["key"] = .string(key) }
        if let value = action.value { object["value"] = .string(value) }
        if let x = action.positionX { object["positionX"] = .number(x) }
        if let y = action.positionY { object["positionY"] = .number(y) }
        if let x = action.deltaX { object["deltaX"] = .number(x) }
        if let y = action.deltaY { object["deltaY"] = .number(y) }
        if let script = action.script { object["script"] = .string(script) }
        if action.kind == .fullPageScreenshot {
            // The coordinator routes full-page capture through the explicit
            // non-read-only approval path before it reaches this broker.
            object["optIn"] = .bool(true)
        }
        if action.kind == .runJavaScript {
            // JavaScript arrives here only after the Computer Use gate binds
            // and consumes its explicit approval.
            object["approved"] = .bool(true)
        }
        return .object(object)
    }
}
