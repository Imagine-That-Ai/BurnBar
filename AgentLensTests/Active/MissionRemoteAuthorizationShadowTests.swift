import Darwin
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Regression coverage for the GUI-to-daemon mission authorization cutover.
/// The fake below is a real newline-framed Unix-socket boundary: responses
/// cross the same Codable/RPC path used in production rather than bypassing
/// authorization with a callback that production never calls.
final class MissionRemoteAuthorizationShadowTests: XCTestCase {

    private let daemonDenialMessage = "This remote mission was not authorized by the Mac daemon and will not run. Re-send the mission from your device."
    private let personaDenialMessage = "The persona scope attached to this mission could not be read, so it was rejected instead of running with broader permissions. Re-send the mission from your device."
    private let cliDisabledMessage = "Mac CLI assistants are off. Enable Mac CLI assistants in Settings -> Privacy & Indexing before this Mac can run remote agent missions."

    private func context(approvalStatus: String = "approved") -> MissionRemoteAuthorizationShadow.ShadowContext {
        MissionRemoteAuthorizationShadow.ShadowContext(
            missionID: "mission-cutover-regression",
            prompt: "Inspect the project without widening permissions",
            runtime: "codex",
            modelID: "gpt-test",
            commandsAllowed: true,
            fileEditsAllowed: true,
            originDeviceID: "phone-1",
            originPlatform: "ios",
            personaScopeJSON: nil,
            approvalMode: "manual_all",
            approvalStatus: approvalStatus,
            approverDeviceID: "phone-1",
            entitlementTier: "none",
            workingDirectory: "/tmp/project",
            fanOutCount: 1
        )
    }

    private func authorizedResponse(
        commandsAllowed: Bool,
        fileEditsAllowed: Bool
    ) -> BurnBarRemoteMissionAuthorizeResponse {
        BurnBarRemoteMissionAuthorizeResponse(
            verdict: .authorized,
            detail: "Daemon policy authorized the attenuated mission.",
            grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest(
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                additionalCapabilities: []
            ),
            backendDecision: BurnBarRemoteMissionBackendDecision(
                runtimeID: "codex",
                modelID: "gpt-test",
                reason: "requested_runtime"
            )
        )
    }

    @MainActor
    private func withMode<T>(
        _ mode: MissionRemoteAuthorizationShadow.Mode,
        operation: () async throws -> T
    ) async rethrows -> T {
        let previous = MissionRemoteAuthorizationShadow.mode
        MissionRemoteAuthorizationShadow.mode = mode
        defer { MissionRemoteAuthorizationShadow.mode = previous }
        return try await operation()
    }

    @MainActor
    private func healthyManager(socketURL: URL) -> OpenBurnBarDaemonManager {
        let root = socketURL.deletingLastPathComponent()
        let daemonDirectory = root.appendingPathComponent("daemon", isDirectory: true)
        let paths = OpenBurnBarDaemonRuntimePaths(
            supportDirectory: root,
            daemonDirectory: daemonDirectory,
            frameworksDirectory: root.appendingPathComponent("Frameworks", isDirectory: true),
            installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon"),
            socketURL: socketURL,
            logURL: daemonDirectory.appendingPathComponent("daemon.log"),
            launchAgentPlistURL: root.appendingPathComponent("launch-agent.plist")
        )
        let manager = OpenBurnBarDaemonManager(paths: paths, dependencies: .live())
        manager.status = .healthy(OpenBurnBarDaemonHealthSnapshot(response: BurnBarHealthResponse(
            ok: true,
            daemonVersion: "authorization-test",
            protocolVersion: BurnBarProtocolVersion.current,
            socketPath: socketURL.path
        )))
        return manager
    }

    @MainActor
    func testEnforcePreservesTheCompleteAuthorizedResponseAndExactGrantCeiling() async throws {
        let expected = authorizedResponse(commandsAllowed: false, fileEditsAllowed: true)
        let daemon = try MissionAuthorizationFakeDaemon(reply: .response(expected))
        defer { daemon.stop() }

        let outcome = await withMode(.enforce) {
            await MissionRemoteAuthorizationShadow.resolveTrustedDecision(
                ctx: context(),
                isTerminalDenial: false,
                personaScopeMalformed: false,
                willPauseForApproval: false,
                manager: healthyManager(socketURL: daemon.socketURL)
            )
        }

        guard case .authorized(let actual) = outcome else {
            XCTFail("A full daemon authorization must reach the listener unchanged; got \(outcome)")
            return
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(
            actual.grantCeiling,
            BurnBarRemoteMissionCapabilityGrantRequest(
                commandsAllowed: false,
                fileEditsAllowed: true,
                additionalCapabilities: []
            )
        )
    }

    @MainActor
    func testEnforceRejectsEveryNonAuthorizingDaemonVerdict() async throws {
        struct Row {
            let name: String
            let response: BurnBarRemoteMissionAuthorizeResponse
        }
        let rows = [
            Row(
                name: "approval still required",
                response: BurnBarRemoteMissionAuthorizeResponse(
                    verdict: .requiresApproval,
                    detail: "Operator approval has not landed.",
                    grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest(
                        commandsAllowed: true,
                        fileEditsAllowed: false
                    )
                )
            ),
            Row(
                name: "policy denied",
                response: BurnBarRemoteMissionAuthorizeResponse(
                    verdict: .denied,
                    deniedReason: .approvalRejected,
                    detail: "Approval was rejected."
                )
            )
        ]

        for row in rows {
            let daemon = try MissionAuthorizationFakeDaemon(reply: .response(row.response))
            defer { daemon.stop() }
            let outcome = await withMode(.enforce) {
                await MissionRemoteAuthorizationShadow.resolveTrustedDecision(
                    ctx: context(),
                    isTerminalDenial: false,
                    personaScopeMalformed: false,
                    willPauseForApproval: false,
                    manager: healthyManager(socketURL: daemon.socketURL)
                )
            }
            XCTAssertEqual(outcome, .deny(daemonDenialMessage), row.name)
        }
    }

    @MainActor
    func testEnforceFailsClosedWhenDaemonIsUnhealthy() async {
        let manager = OpenBurnBarDaemonManager()
        manager.status = .unhealthy("authorization service unavailable")

        let outcome = await withMode(.enforce) {
            await MissionRemoteAuthorizationShadow.resolveTrustedDecision(
                ctx: context(),
                isTerminalDenial: false,
                personaScopeMalformed: false,
                willPauseForApproval: false,
                manager: manager
            )
        }

        XCTAssertEqual(outcome, .deny(daemonDenialMessage))
    }

    @MainActor
    func testEnforceFailsClosedWhenAuthorizationRPCReturnsAnError() async throws {
        let daemon = try MissionAuthorizationFakeDaemon(
            reply: .rpcError(code: 503, message: "authorization policy unavailable")
        )
        defer { daemon.stop() }

        let outcome = await withMode(.enforce) {
            await MissionRemoteAuthorizationShadow.resolveTrustedDecision(
                ctx: context(),
                isTerminalDenial: false,
                personaScopeMalformed: false,
                willPauseForApproval: false,
                manager: healthyManager(socketURL: daemon.socketURL)
            )
        }

        XCTAssertEqual(outcome, .deny(daemonDenialMessage))
    }

    @MainActor
    func testLocalFailClosedGuardsStillDenyAfterDaemonAuthorization() async throws {
        struct Row {
            let name: String
            let terminalDenial: Bool
            let personaMalformed: Bool
            let expectedMessage: String
        }
        let rows = [
            Row(
                name: "malformed persona scope",
                terminalDenial: false,
                personaMalformed: true,
                expectedMessage: personaDenialMessage
            ),
            Row(
                name: "Mac CLI assistants disabled",
                terminalDenial: true,
                personaMalformed: false,
                expectedMessage: cliDisabledMessage
            )
        ]

        for row in rows {
            let daemon = try MissionAuthorizationFakeDaemon(
                reply: .response(authorizedResponse(commandsAllowed: true, fileEditsAllowed: true))
            )
            defer { daemon.stop() }
            let outcome = await withMode(.enforce) {
                await MissionRemoteAuthorizationShadow.resolveTrustedDecision(
                    ctx: context(),
                    isTerminalDenial: row.terminalDenial,
                    personaScopeMalformed: row.personaMalformed,
                    willPauseForApproval: row.terminalDenial,
                    manager: healthyManager(socketURL: daemon.socketURL)
                )
            }
            XCTAssertEqual(outcome, .deny(row.expectedMessage), row.name)
        }
    }

    @MainActor
    func testOffAndShadowKeepTheExistingPauseDenyProceedOutcomes() async {
        struct Row {
            let mode: MissionRemoteAuthorizationShadow.Mode
            let name: String
            let malformed: Bool
            let pauses: Bool
            let expected: MissionAuthorizationTrustedDecisionOutcome
        }
        let rows: [Row] = [.off, .shadow].flatMap { mode in
            [
                Row(mode: mode, name: "pause", malformed: false, pauses: true, expected: .pauseForApproval),
                Row(mode: mode, name: "persona denial", malformed: true, pauses: false, expected: .deny(personaDenialMessage)),
                Row(mode: mode, name: "proceed", malformed: false, pauses: false, expected: .proceed)
            ]
        }

        let sharedManager = OpenBurnBarDaemonManager.shared
        let previousStatus = sharedManager.status
        sharedManager.status = .unhealthy("isolated authorization regression test")
        defer { sharedManager.status = previousStatus }

        for row in rows {
            let outcome = await withMode(row.mode) {
                let result = await MissionRemoteAuthorizationShadow.resolveTrustedDecision(
                    ctx: context(approvalStatus: row.pauses ? "pending" : "approved"),
                    isTerminalDenial: false,
                    personaScopeMalformed: row.malformed,
                    willPauseForApproval: row.pauses
                )
                await Task.yield()
                await Task.yield()
                return result
            }
            XCTAssertEqual(outcome, row.expected, "\(row.mode.rawValue): \(row.name)")
        }
    }

    func testPresentNonStringOrMalformedPersonaScopeIsRejected() {
        let malformedValues: [Any] = [
            7,
            true,
            ["permitShell": false],
            ["not", "an", "object"],
            "{not valid JSON"
        ]

        for value in malformedValues {
            let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
                from: ["personaScopeJSON": value]
            )
            guard case .refused(let message) = resolution else {
                XCTFail("Present malformed persona scope \(String(describing: value)) must fail closed; got \(resolution)")
                continue
            }
            XCTAssertEqual(message, personaDenialMessage)
        }
    }
}

private final class MissionAuthorizationFakeDaemon: @unchecked Sendable {
    enum Reply: Sendable {
        case response(BurnBarRemoteMissionAuthorizeResponse)
        case rpcError(code: Int, message: String)
    }

    let socketURL: URL

    private let listenerDescriptor: Int32
    private let reply: Reply
    private let queue = DispatchQueue(label: "mission-authorization-fake-daemon")
    private let lock = NSLock()
    private var stopped = false

    init(reply: Reply) throws {
        self.reply = reply
        let path = "/tmp/obb-mission-auth-\(UUID().uuidString.prefix(8)).sock"
        socketURL = URL(fileURLWithPath: path)
        listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerDescriptor != -1 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(listenerDescriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                bytes[index] = byte
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bindResult == 0, listen(listenerDescriptor, 4) == 0 else {
            close(listenerDescriptor)
            throw POSIXError(.EIO)
        }
        queue.async { [weak self] in self?.acceptRequests() }
    }

    func stop() {
        lock.withLock { stopped = true }
        close(listenerDescriptor)
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptRequests() {
        while true {
            let client = accept(listenerDescriptor, nil, nil)
            if client == -1 {
                if lock.withLock({ stopped }) || errno == EBADF { return }
                continue
            }
            respond(to: client)
        }
    }

    private func respond(to client: Int32) {
        defer { close(client) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
            if request.last == 0x0A { break }
        }
        while request.last == 0x0A || request.last == 0x0D { request.removeLast() }
        guard
            let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
            let requestID = object["id"] as? String,
            object["method"] as? String == BurnBarRPCMethod.missionAuthorizeRemote.rawValue
        else { return }

        let responseData: Data
        do {
            switch reply {
            case .response(let response):
                responseData = try JSONEncoder().encode(
                    BurnBarRPCResponseEnvelope(id: requestID, result: response)
                )
            case .rpcError(let code, let message):
                responseData = try JSONEncoder().encode(
                    BurnBarRPCResponseEnvelope<BurnBarRemoteMissionAuthorizeResponse>(
                        id: requestID,
                        error: BurnBarRPCError(code: code, message: message)
                    )
                )
            }
        } catch {
            return
        }

        let payload = responseData + Data([0x0A])
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(client, base.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
