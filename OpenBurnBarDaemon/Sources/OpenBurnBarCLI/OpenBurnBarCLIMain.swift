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
        let socketAuthToken = Self.resolveSocketAuthToken(environment: environment)
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

    private static func resolveSocketAuthToken(environment: [String: String]) -> String? {
        if let token = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"] {
            return token.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        #if os(Linux)
        let tokenURL = OpenBurnBarLinuxPaths.authTokenURL(environment: environment)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: tokenURL.path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o077 == 0,
              let token = try? String(contentsOf: tokenURL, encoding: .utf8),
              let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return trimmed
        #else
        return nil
        #endif
    }

    private static func writeLine(_ text: String, toStandardError: Bool = false) {
        let data = Data((text + "\n").utf8)
        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        try? handle.write(contentsOf: data)
    }
}
