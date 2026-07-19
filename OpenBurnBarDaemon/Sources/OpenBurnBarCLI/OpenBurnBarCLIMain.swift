import OpenBurnBarDaemon
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        let socketAuthToken: String?
        do {
            socketAuthToken = try BurnBarCLISocketClient.resolvedSocketAuthToken(environment: environment)
        } catch {
            writeLine(Self.message(for: error), toStandardError: true)
            exit(EXIT_FAILURE)
        }
        let socketURL = BurnBarCLISocketClient.resolvedSocketURL(environment: environment)
        let client = BurnBarCLISocketClient(socketURL: socketURL, authToken: socketAuthToken)

        if arguments == ["privacy-rpc"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                writeLine(try BurnBarCLIRunner(client: client).runPrivacyRPC(input: input))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        if BurnBarCLIRunner.shouldUseHealthFastPath(
            arguments: arguments,
            invokedExecutablePath: CommandLine.arguments.first
        ) {
            do {
                writeLine(BurnBarCLIHealthFormatter.format(try client.health()))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
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
            writeLine(Self.message(for: error), toStandardError: true)
            exitCode = EXIT_FAILURE
        }

        exit(exitCode)
    }

    private static func message(for error: any Error) -> String {
        error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
    }

    private static func writeLine(_ text: String, toStandardError: Bool = false) {
        let data = Data((text + "\n").utf8)
        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        try? handle.write(contentsOf: data)
    }
}
