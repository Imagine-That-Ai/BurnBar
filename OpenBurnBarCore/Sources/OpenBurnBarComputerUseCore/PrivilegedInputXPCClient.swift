import Foundation

/// XPC client for the privileged input-execution Mach service (preferred over legacy Unix socket).
public final class PrivilegedInputXPCClient: NSObject, @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case connectionUnavailable
        case remoteProxyUnavailable
        case invalidResponse
        case timedOut
        case rejected(String)
    }

    private let machServiceName: String
    private let requestTimeout: DispatchTimeInterval
    private let lock = NSLock()
    private var cachedConnections: [ConnectionMode: NSXPCConnection] = [:]

    public init(
        machServiceName: String = PrivilegedInputXPCConstants.machServiceName,
        requestTimeout: DispatchTimeInterval = .seconds(4)
    ) {
        self.machServiceName = machServiceName
        self.requestTimeout = requestTimeout
        super.init()
    }

    public func perform(_ envelope: PrivilegedInputDispatchEnvelope) throws -> PrivilegedInputDispatchResponse {
        var lastConnectionError: Error?
        for mode in ConnectionMode.preferredOrder {
            do {
                return try perform(envelope, mode: mode)
            } catch ClientError.rejected(let detail) {
                throw ClientError.rejected(detail)
            } catch {
                invalidateConnection(for: mode)
                lastConnectionError = error
            }
        }
        throw lastConnectionError ?? ClientError.connectionUnavailable
    }

    private func perform(
        _ envelope: PrivilegedInputDispatchEnvelope,
        mode: ConnectionMode
    ) throws -> PrivilegedInputDispatchResponse {
        let connection = try connection(mode: mode)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let payload = try encoder.encode(envelope)

        var responseData: Data?
        var remoteError: NSError?
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            remoteError = error as NSError
            semaphore.signal()
        }) as? PrivilegedInputExecutionXPCProtocol else {
            throw ClientError.remoteProxyUnavailable
        }
        proxy.perform(payload) { data, error in
            responseData = data
            remoteError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else {
            throw ClientError.timedOut
        }

        if let remoteError {
            throw remoteError
        }
        guard let responseData,
              let response = try? decoder.decode(PrivilegedInputDispatchResponse.self, from: responseData) else {
            throw ClientError.invalidResponse
        }
        guard response.ok else {
            throw ClientError.rejected(response.error ?? "privileged_input_rejected")
        }
        return response
    }

    private func connection(mode: ConnectionMode) throws -> NSXPCConnection {
#if os(macOS)
        lock.lock()
        defer { lock.unlock() }

        let connection: NSXPCConnection
        if let cached = cachedConnections[mode] {
            connection = cached
        } else {
            let created = NSXPCConnection(
                machServiceName: machServiceName,
                options: mode.options
            )
            created.remoteObjectInterface = NSXPCInterface(with: PrivilegedInputExecutionXPCProtocol.self)
            created.invalidationHandler = { [weak self] in
                self?.invalidateConnection(for: mode)
            }
            created.interruptionHandler = created.invalidationHandler
            created.resume()
            cachedConnections[mode] = created
            connection = created
        }

        return connection
#else
        throw ClientError.connectionUnavailable
#endif
    }

    private func invalidateConnection(for mode: ConnectionMode) {
        lock.lock()
        let connection = cachedConnections.removeValue(forKey: mode)
        lock.unlock()
        connection?.invalidate()
    }

    private enum ConnectionMode: Hashable {
        case userSession
        case privilegedSystem

        static let preferredOrder: [ConnectionMode] = [.userSession, .privilegedSystem]

        var options: NSXPCConnection.Options {
            switch self {
            case .userSession:
                return []
            case .privilegedSystem:
                return .privileged
            }
        }
    }
}
