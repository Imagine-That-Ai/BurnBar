import OpenBurnBarDaemon
import Foundation

@main
struct BurnBarCLIExecutable {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let result = BurnBarCLIRunner.startupPreflightResult(
            arguments: arguments,
            invokedExecutablePath: CommandLine.arguments.first
        ) {
            writeLine(result.output, toStandardError: result.writesToStandardError)
            exit(result.exitCode)
        }

        let environment = ProcessInfo.processInfo.environment
        let socketAuthToken = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
        let socketURL = BurnBarCLISocketClient.resolvedSocketURL(environment: environment)
        let client = BurnBarCLISocketClient(socketURL: socketURL, authToken: socketAuthToken)

        if BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: arguments,
            invokedExecutablePath: CommandLine.arguments.first
        ) {
            do {
                writeLine(BurnBarCLIHealthFormatter.format(try client.health()))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(errorText(error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        let runner = BurnBarCLIRunner(client: client)
        let exitCode: Int32

        do {
            let result = try await runner.invoke(
                arguments: arguments,
                invokedExecutablePath: CommandLine.arguments.first
            )
            if let output = result.output, !output.isEmpty {
                writeLine(output)
            }
            exitCode = result.exitCode
        } catch {
            writeLine(errorText(error), toStandardError: true)
            exitCode = EXIT_FAILURE
        }

        exit(exitCode)
    }

    private static func writeLine(_ text: String, toStandardError: Bool = false) {
        guard let data = "\(text)\n".data(using: .utf8) else { return }
        if toStandardError {
            FileHandle.standardError.write(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func errorText(_ error: Error) -> String {
        error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
    }
}
