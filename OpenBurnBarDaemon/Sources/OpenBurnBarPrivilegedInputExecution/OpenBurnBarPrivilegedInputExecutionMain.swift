import Darwin
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
        signal(SIGPIPE, SIG_IGN)
        do {
            let keyboard = try VirtualHIDKeyboardEngine()
            let socketPath = argumentValue("--socket") ?? PrivilegedInputXPCConstants.userSessionSocketPath()
            let handler = PrivilegedInputDispatchHandler(
                auditSocketLabel: socketPath,
                keyboard: keyboard
            )
            let server = try PrivilegedInputExecutionSocketServer(socketPath: socketPath) { envelope in
                try handler.handle(envelope: envelope)
            }
            executionLog("listening socket=\(socketPath)")
            server.run()
            executionLog("stopped socket=\(socketPath)")
        } catch {
            executionLog("fatal detail=\(String(describing: error))")
            exit(1)
        }
    }
}

private func argumentValue(_ name: String, in args: [String] = CommandLine.arguments) -> String? {
    guard let index = args.firstIndex(of: name),
          args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}
