import OpenBurnBarDaemon
import Foundation

@main
struct BurnBarCLIExecutable {
    static func main() {
        let runner = BurnBarCLIRunner(client: BurnBarCLISocketClient())
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode = Int32(EXIT_FAILURE)

        Task {
            defer { semaphore.signal() }

            do {
                let result = try await runner.invoke(
                    arguments: Array(CommandLine.arguments.dropFirst()),
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
        }

        semaphore.wait()
        exit(exitCode)
    }
}
