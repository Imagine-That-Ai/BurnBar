import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarRemoteAccessAgentCore

private func executionLog(_ message: String) {
    let line = "privileged_input_execution \(Date().timeIntervalSince1970): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

@main
struct OpenBurnBarPrivilegedInputExecutionMain {
    static func main() {
        do {
            let keyboard = try VirtualHIDKeyboardEngine()
            let handler = PrivilegedInputDispatchHandler(
                auditSocketLabel: PrivilegedInputXPCConstants.machServiceName,
                keyboard: keyboard
            )
            let service = PrivilegedInputExecutionXPCService(handler: handler)
            let listener = NSXPCListener(machServiceName: PrivilegedInputXPCConstants.machServiceName)
            listener.delegate = service
            executionLog("listening mach=\(PrivilegedInputXPCConstants.machServiceName)")
            listener.resume()
            RunLoop.main.run()
        } catch {
            executionLog("fatal detail=\(String(describing: error))")
            exit(1)
        }
    }
}

private final class PrivilegedInputExecutionXPCService: NSObject, NSXPCListenerDelegate {
    private let handler: PrivilegedInputDispatchHandler

    init(handler: PrivilegedInputDispatchHandler) {
        self.handler = handler
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try PrivilegedInputXPCPeerValidator.validateConnection(connection)
        } catch {
            executionLog("xpc peer rejected detail=\(String(describing: error))")
            PrivilegedSocketAudit.record(
                PrivilegedSocketAuditRecord(
                    event: .peerRejected,
                    socket: PrivilegedInputXPCConstants.machServiceName,
                    detail: String(describing: error)
                )
            )
            return false
        }

        PrivilegedSocketAudit.record(
            PrivilegedSocketAuditRecord(
                event: .peerAccepted,
                socket: PrivilegedInputXPCConstants.machServiceName
            )
        )

        let exported = PrivilegedInputExecutionExportedObject(handler: handler)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedInputExecutionXPCProtocol.self)
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}

private final class PrivilegedInputExecutionExportedObject: NSObject, PrivilegedInputExecutionXPCProtocol {
    private let handler: PrivilegedInputDispatchHandler
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(handler: PrivilegedInputDispatchHandler) {
        self.handler = handler
    }

    func perform(_ envelopeData: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let envelope = try decoder.decode(PrivilegedInputDispatchEnvelope.self, from: envelopeData)
            let response = try handler.handle(envelope: envelope)
            let data = try encoder.encode(response)
            reply(data, nil)
        } catch {
            let response = PrivilegedInputDispatchResponse(
                ok: false,
                error: (error as? VirtualHIDKeyboardEngine.EngineError)?.rawValue ?? "request_failed"
            )
            let data = try? encoder.encode(response)
            reply(data, nil)
        }
    }
}
