import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

/// Exercises `IrohXcframeworkTransport` end-to-end against a fake
/// `IrohEndpointBackend`. The fake mirrors the Rust crate's eight-function
/// surface (bootstrap / identity / connect / acceptOne / shutdown +
/// stream send/recv/close) so the adapter behaves identically whether the
/// underlying handle is UniFFI-generated or unit-tested.
final class IrohXcframeworkTransportTests: XCTestCase {
    func testBootstrapAndIdentityRoundTrip() async throws {
        let rendezvous = FakeBackendRendezvous()
        let backend = FakeEndpointBackend(nodeId: "mac-fake", rendezvous: rendezvous)
        let transport = IrohXcframeworkTransport(backend: backend) {
            IrohSecretKeyMaterial(raw: Data(repeating: 0x11, count: 32))
        }

        let identity = try await transport.start()
        XCTAssertEqual(identity.nodeId, "mac-fake")
        XCTAssertEqual(identity.rawPublicKey.count, 32)

        // Calling start twice returns the cached identity.
        let again = try await transport.start()
        XCTAssertEqual(again, identity)

        await transport.shutdown()
    }

    func testEchoOverFakeBackend() async throws {
        let rendezvous = FakeBackendRendezvous()
        let macBackend = FakeEndpointBackend(nodeId: "mac-iroh", rendezvous: rendezvous)
        let iosBackend = FakeEndpointBackend(nodeId: "ios-iroh", rendezvous: rendezvous)

        let macTransport = IrohXcframeworkTransport(backend: macBackend) {
            IrohSecretKeyMaterial(raw: Data(repeating: 0x22, count: 32))
        }
        let iosTransport = IrohXcframeworkTransport(backend: iosBackend) {
            IrohSecretKeyMaterial(raw: Data(repeating: 0x33, count: 32))
        }

        _ = try await macTransport.start()
        _ = try await iosTransport.start()

        let relayPrivateKey = HermesRelayCrypto.generatePrivateKey()
        let host = HermesIrohEchoHost(privateKey: relayPrivateKey)
        let client = HermesIrohEchoClient()

        let hostTask = Task<Void, Error> {
            let stream = try await macTransport.accept(timeout: 5)
            try await host.serve(on: stream)
        }

        let outbound = try await iosTransport.connect(to: "mac-iroh", timeout: 5)
        let response = try await client.roundTrip(
            request: .init(
                uid: "u-fake",
                connectionId: "c-fake",
                requestId: "r-fake-1",
                plaintextBody: "hello fake iroh"
            ),
            on: outbound,
            recipientPublicKeyBase64: relayPrivateKey.publicKeyBase64
        )
        XCTAssertEqual(response.body, "hello fake iroh")
        XCTAssertEqual(response.chunkCount, 1)
        try await hostTask.value

        await iosTransport.shutdown()
        await macTransport.shutdown()
    }

    func testConnectTimeoutSurfacesAsTimedOut() async throws {
        let rendezvous = FakeBackendRendezvous()
        let backend = FakeEndpointBackend(nodeId: "ios-only", rendezvous: rendezvous)
        let transport = IrohXcframeworkTransport(backend: backend) {
            IrohSecretKeyMaterial(raw: Data(repeating: 0x44, count: 32))
        }
        _ = try await transport.start()

        do {
            _ = try await transport.connect(to: "nobody-here", timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? IrohRelayTransportError, .timedOut)
        }
        await transport.shutdown()
    }

    func testStartFailurePropagatesAndResetsState() async throws {
        let backend = FailingBootstrapBackend()
        let transport = IrohXcframeworkTransport(backend: backend) {
            IrohSecretKeyMaterial(raw: Data(repeating: 0x55, count: 32))
        }
        do {
            _ = try await transport.start()
            XCTFail("expected runtime failure")
        } catch IrohRelayTransportError.streamRejected {
            // expected
        } catch {
            XCTFail("expected streamRejected; got \(error)")
        }
        // After a failed start the backend should be marked stopped.
        do {
            _ = try await transport.connect(to: "x", timeout: 0.1)
            XCTFail("expected endpointNotReady")
        } catch {
            XCTAssertEqual(error as? IrohRelayTransportError, .endpointNotReady)
        }
    }

    func testStartRetriesTransientHomeRelayBootstrapTimeoutOnce() async throws {
        let rendezvous = FakeBackendRendezvous()
        let backend = FakeEndpointBackend(nodeId: "ios-retry", rendezvous: rendezvous)
        backend.bootstrapErrors = [
            .runtimeFailed("iroh endpoint did not select a home relay within 10s")
        ]
        let transport = IrohXcframeworkTransport(
            backend: backend,
            secretProvider: {
                IrohSecretKeyMaterial(raw: Data(repeating: 0x66, count: 32))
            },
            bootstrapRetryDelayNanoseconds: 0
        )

        let identity = try await transport.start()

        XCTAssertEqual(identity.nodeId, "ios-retry")
        XCTAssertEqual(backend.bootstrapAttempts, 2)
        XCTAssertEqual(backend.shutdownCount, 1)
        await transport.shutdown()
    }
}

// MARK: - Fakes

actor FakeBackendRendezvous {
    private var hosts: [String: FakeEndpointBackend] = [:]

    func register(_ backend: FakeEndpointBackend, nodeId: String) {
        hosts[nodeId] = backend
    }

    func unregister(nodeId: String) {
        hosts.removeValue(forKey: nodeId)
    }

    func dial(to nodeId: String, from dialer: FakeEndpointBackend) async throws -> FakeBackendStream {
        guard let host = hosts[nodeId] else {
            throw IrohBackendError.connectFailed("rendezvous timed out: \(nodeId) not registered")
        }
        let pair = FakeBackendStreamPair()
        let clientStream = FakeBackendStream(send: pair.clientToHost, recv: pair.hostToClient)
        let hostStream = FakeBackendStream(send: pair.hostToClient, recv: pair.clientToHost)
        await host.enqueueInbound(hostStream)
        return clientStream
    }
}

final class FakeEndpointBackend: IrohEndpointBackend, @unchecked Sendable {
    private let nodeId: String
    private let rendezvous: FakeBackendRendezvous
    private var registered = false
    private var acceptQueue = FakeBackendAcceptQueue()
    var bootstrapErrors: [IrohBackendError] = []
    private(set) var bootstrapAttempts = 0
    private(set) var shutdownCount = 0

    init(nodeId: String, rendezvous: FakeBackendRendezvous) {
        self.nodeId = nodeId
        self.rendezvous = rendezvous
    }

    func bootstrap(secret: Data, relayURL: String?) async throws -> IrohEndpointIdentity {
        bootstrapAttempts += 1
        if !bootstrapErrors.isEmpty {
            throw bootstrapErrors.removeFirst()
        }
        guard secret.count == 32 else { throw IrohBackendError.invalidSecretKey }
        await rendezvous.register(self, nodeId: nodeId)
        registered = true
        return IrohEndpointIdentity(
            nodeId: nodeId,
            rawPublicKey: Data(repeating: 0xAB, count: 32),
            relayURL: relayURL
        )
    }

    func identity() async throws -> IrohEndpointIdentity {
        guard registered else { throw IrohBackendError.notInitialized }
        return IrohEndpointIdentity(
            nodeId: nodeId,
            rawPublicKey: Data(repeating: 0xAB, count: 32)
        )
    }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> IrohBackendStream {
        guard registered else { throw IrohBackendError.notInitialized }
        let dialerSelf = self
        return try await withThrowingTaskGroup(of: FakeBackendStream.self) { group in
            group.addTask {
                try await self.rendezvous.dial(to: target.nodeId, from: dialerSelf)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw IrohBackendError.connectFailed("iroh connect timed out")
            }
            let stream = try await group.next()!
            group.cancelAll()
            return stream
        }
    }

    func acceptOne(timeout: TimeInterval) async throws -> IrohBackendStream {
        guard registered else { throw IrohBackendError.notInitialized }
        return try await acceptQueue.pop(timeout: timeout)
    }

    func shutdown() async {
        shutdownCount += 1
        registered = false
        await rendezvous.unregister(nodeId: nodeId)
        await acceptQueue.close()
        acceptQueue = FakeBackendAcceptQueue()
    }

    func enqueueInbound(_ stream: FakeBackendStream) async {
        await acceptQueue.push(stream)
    }
}

actor FakeBackendAcceptQueue {
    private var pending: [FakeBackendStream] = []
    private var waiter: CheckedContinuation<FakeBackendStream, Error>?
    private var closed = false

    func push(_ stream: FakeBackendStream) {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: stream)
            return
        }
        pending.append(stream)
    }

    func pop(timeout: TimeInterval) async throws -> FakeBackendStream {
        if !pending.isEmpty { return pending.removeFirst() }
        if closed { throw IrohBackendError.acceptFailed("backend closed") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FakeBackendStream, Error>) in
            self.waiter = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeOut()
            }
        }
    }

    func close() {
        closed = true
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(throwing: IrohBackendError.acceptFailed("backend closed"))
        }
    }

    private func timeOut() {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(throwing: IrohBackendError.acceptFailed("iroh accept timed out"))
        }
    }
}

actor FakeBackendBytes {
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false

    func push(_ data: Data) {
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: data)
            return
        }
        queue.append(data)
    }

    func pop() async -> Data? {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            self.waiter = cont
        }
    }

    func close() {
        closed = true
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

struct FakeBackendStreamPair {
    let clientToHost: FakeBackendBytes
    let hostToClient: FakeBackendBytes
    init() {
        self.clientToHost = FakeBackendBytes()
        self.hostToClient = FakeBackendBytes()
    }
}

final class FakeBackendStream: IrohBackendStream, @unchecked Sendable {
    private let sendQueue: FakeBackendBytes
    private let recvQueue: FakeBackendBytes

    init(send: FakeBackendBytes, recv: FakeBackendBytes) {
        self.sendQueue = send
        self.recvQueue = recv
    }

    func sendFrame(_ envelope: Data) async throws {
        await sendQueue.push(envelope)
    }

    func recvFrame() async throws -> Data? {
        await recvQueue.pop()
    }

    func close() async {
        await sendQueue.close()
    }
}

final class FailingBootstrapBackend: IrohEndpointBackend, @unchecked Sendable {
    func bootstrap(secret: Data, relayURL: String?) async throws -> IrohEndpointIdentity {
        throw IrohBackendError.runtimeFailed("simulated bootstrap failure")
    }
    func identity() async throws -> IrohEndpointIdentity {
        throw IrohBackendError.notInitialized
    }
    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> IrohBackendStream {
        throw IrohBackendError.notInitialized
    }
    func acceptOne(timeout: TimeInterval) async throws -> IrohBackendStream {
        throw IrohBackendError.notInitialized
    }
    func shutdown() async {}
}
