import Foundation

/// XPC client for the privileged input-execution Mach service (preferred over legacy Unix socket).
public final class PrivilegedInputXPCClient: NSObject, @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case connectionUnavailable
        case remoteProxyUnavailable
        case invalidResponse
        case rejected(String)
    }

    private let machServiceName: String
    private let lock = NSLock()
    private var cachedConnection: NSXPCConnection?

    public init(machServiceName: String = PrivilegedInputXPCConstants.machServiceName) {
        self.machServiceName = machServiceName
        super.init()
    }

    public func perform(_ envelope: PrivilegedInputDispatchEnvelope) throws -> PrivilegedInputDispatchResponse {
        let proxy = try remoteProxy()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let payload = try encoder.encode(envelope)

        var responseData: Data?
        var remoteError: NSError?
        let semaphore = DispatchSemaphore(value: 0)
        proxy.perform(payload) { data, error in
            responseData = data
            remoteError = error
            semaphore.signal()
        }
        semaphore.wait()

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

    private func remoteProxy() throws -> PrivilegedInputExecutionXPCProtocol {
#if os(macOS)
        lock.lock()
        defer { lock.unlock() }

        let connection: NSXPCConnection
        if let cached = cachedConnection {
            connection = cached
        } else {
            let created = NSXPCConnection(
                machServiceName: machServiceName,
                options: .privileged
            )
            created.remoteObjectInterface = NSXPCInterface(with: PrivilegedInputExecutionXPCProtocol.self)
            created.invalidationHandler = { [weak self] in
                self?.lock.lock()
                self?.cachedConnection = nil
                self?.lock.unlock()
            }
            created.interruptionHandler = created.invalidationHandler
            created.resume()
            cachedConnection = created
            connection = created
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? PrivilegedInputExecutionXPCProtocol else {
            throw ClientError.remoteProxyUnavailable
        }
        return proxy
#else
        throw ClientError.connectionUnavailable
#endif
    }
}
