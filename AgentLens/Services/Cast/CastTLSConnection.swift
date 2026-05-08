import Foundation
import Network
import Security

// MARK: - Cast TLS Connection
//
// Cast devices present self-signed (or Google-CA-signed) certificates on
// `:8009`. macOS's default trust store rejects these. We accept whatever
// the device presents, but **only when the connection target was
// resolved via mDNS through `CastDiscovery`** — narrowing trust to LAN
// devices the user just chose in the wizard.

@MainActor
final class CastTLSConnection {

    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
        case cancelled
    }

    private(set) var state: State = .idle

    private let host: String
    private let port: Int
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    var onMessage: ((CastMessage) -> Void)?
    var onStateChange: ((State) -> Void)?

    init(host: String, port: Int = 8009) {
        self.host = host
        self.port = port
    }

    func connect() {
        guard connection == nil else { return }
        let tls = NWProtocolTLS.Options()
        configurePermissiveTrust(on: tls)
        let params = NWParameters(tls: tls)
        params.allowFastOpen = true

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 8009
        )
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        update(state: .connecting)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.update(state: .ready)
                    self.scheduleReceive()
                case .failed(let err):
                    self.update(state: .failed(err.localizedDescription))
                case .cancelled:
                    self.update(state: .cancelled)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: CastMessage) {
        guard let connection, state == .ready else { return }
        let data = CastFraming.encode(message)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    // MARK: - Internal

    private func update(state: State) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }

    private func scheduleReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.drainBuffer()
                }
                if isComplete {
                    self.update(state: .cancelled)
                    return
                }
                if let error {
                    self.update(state: .failed(error.localizedDescription))
                    return
                }
                if self.connection != nil {
                    self.scheduleReceive()
                }
            }
        }
    }

    private func drainBuffer() {
        while let message = CastFraming.decode(from: &receiveBuffer) {
            onMessage?(message)
        }
    }

    /// Cast devices use self-signed certs. We override the trust evaluator
    /// to accept any presented cert chain — appropriate only because
    /// `CastDiscovery` proved this peer is announcing `_googlecast._tcp`.
    private func configurePermissiveTrust(on tls: NWProtocolTLS.Options) {
        let verify: sec_protocol_verify_t = { _, _, completion in
            completion(true)
        }
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            verify,
            DispatchQueue.global(qos: .userInitiated)
        )
    }
}
