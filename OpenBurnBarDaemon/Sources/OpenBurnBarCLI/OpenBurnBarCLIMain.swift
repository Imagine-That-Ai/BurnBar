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
            let stream = result.writesToStandardError ? stderr : stdout
            fputs(result.output + "\n", stream)
            exit(result.exitCode)
        }

        let environment = ProcessInfo.processInfo.environment
        let socketAuthToken = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
        let socketURL = BurnBarCLISocketClient.resolvedSocketURL(environment: environment)
        let client = BurnBarCLISocketClient(socketURL: socketURL, authToken: socketAuthToken)

        if arguments == ["health"] {
            do {
                fputs(BurnBarCLIHealthFormatter.format(try client.health()) + "\n", stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs((error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription) + "\n", stderr)
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
                fputs(output + "\n", stdout)
            }
            exitCode = result.exitCode
        } catch {
            fputs((error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription) + "\n", stderr)
            exitCode = EXIT_FAILURE
        }

        exit(exitCode)
    }
}
