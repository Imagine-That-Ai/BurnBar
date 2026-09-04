import OpenBurnBarDaemon
import OpenBurnBarEngine
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

        #if os(Linux)
        if arguments == ["text-expansion-engine-expand"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 64 * 1024 else {
                    throw BurnBarCLIError.missingArgument("text expansion request exceeds 64 KiB")
                }
                let request = try JSONDecoder().decode(
                    BurnBarTextExpansionEngineExpandRequest.self,
                    from: input
                )
                let response = try client.textExpansionEngineExpand(request)
                let output = try JSONEncoder().encode(response)
                writeLine(String(decoding: output, as: UTF8.self))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }
        #endif

        if arguments == ["search-sql"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 256 * 1024 else {
                    throw BurnBarCLIError.missingArgument("search-sql request exceeds 256 KiB")
                }
                writeLine(try BurnBarCLIRunner(client: client).runSearchSQL(input: input))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        if arguments == ["memory-model-policy"] {
            do {
                writeLine(try BurnBarCLIRunner(client: client).runMemoryModelPolicy())
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        if arguments == ["memory-remember"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 256 * 1024 else {
                    throw BurnBarCLIError.missingArgument("memory-remember request exceeds 256 KiB")
                }
                writeLine(try BurnBarCLIRunner(client: client).runMemoryRemember(input: input))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        if arguments == ["memory-forget"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 256 * 1024 else {
                    throw BurnBarCLIError.missingArgument("memory-forget request exceeds 256 KiB")
                }
                writeLine(try BurnBarCLIRunner(client: client).runMemoryForget(input: input))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        // Memory Blind Sync: the drain the Python memory engine calls on signed
        // installs, wired exactly like `search-sql` / `memory-remember` above.
        if arguments == ["memory-sync-inbox-list"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 256 * 1024 else {
                    throw BurnBarCLIError.missingArgument("memory-sync-inbox-list request exceeds 256 KiB")
                }
                writeLine(try BurnBarCLIRunner(client: client).runMemorySyncInboxList(input: input))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

        if arguments == ["memory-sync-inbox-ack"] {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count <= 256 * 1024 else {
                    throw BurnBarCLIError.missingArgument("memory-sync-inbox-ack request exceeds 256 KiB")
                }
                writeLine(try BurnBarCLIRunner(client: client).runMemorySyncInboxAck(input: input))
                exit(EXIT_SUCCESS)
            } catch {
                writeLine(Self.message(for: error), toStandardError: true)
                exit(EXIT_FAILURE)
            }
        }

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
