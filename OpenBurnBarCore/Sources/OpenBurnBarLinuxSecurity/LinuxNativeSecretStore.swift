import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LinuxSecretCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public typealias LinuxSecretCommandRunner = @Sendable (
    _ executableURL: URL,
    _ arguments: [String],
    _ standardInput: Data?
) throws -> LinuxSecretCommandResult

public enum LinuxNativeSecretStoreKind: String, Sendable {
    case secretService = "org.freedesktop.secrets"
    case kwallet

    var trustLevel: LinuxSecretTrustLevel {
        switch self {
        case .secretService: .secretService
        case .kwallet: .kwallet
        }
    }
}

public struct LinuxNativeSecretStoreBackend: LinuxSecretStoreBackend {
    public let kind: LinuxNativeSecretStoreKind
    public let executableURL: URL
    public let walletName: String
    public let folderName: String
    public let nowMillis: @Sendable () -> Int64
    public let runner: LinuxSecretCommandRunner

    public var backendName: String { kind.rawValue }
    public var trustLevel: LinuxSecretTrustLevel { kind.trustLevel }
    public var supportsMutations: Bool { true }

    public init(
        kind: LinuxNativeSecretStoreKind,
        executableURL: URL,
        walletName: String = "kdewallet",
        folderName: String = "OpenBurnBar",
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        runner: @escaping LinuxSecretCommandRunner = LinuxSecretProcess.run
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.walletName = walletName
        self.folderName = folderName
        self.nowMillis = nowMillis
        self.runner = runner
    }

    public func readSecret(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretRecord? {
        try validate(id: id)
        let result = try execute(arguments: readArguments(id: id, secretClass: secretClass))
        if result.exitCode != 0 {
            if isMissing(result) { return nil }
            throw commandError(operation: "read", result: result)
        }
        var secret = result.stdout
        if secret.hasSuffix("\n") {
            secret.removeLast()
            if secret.hasSuffix("\r") {
                secret.removeLast()
            }
        }
        guard secret.isEmpty == false else { return nil }
        guard secret.contains("\0") == false,
              secret.contains("\n") == false,
              secret.contains("\r") == false else {
            throw LinuxSecretStoreError.invalidSecretValue(
                "the native backend returned a multiline or NUL-containing value"
            )
        }
        guard secret.utf8.count <= 16_384 else {
            throw LinuxSecretStoreError.secretTooLarge(secret.utf8.count)
        }
        return LinuxSecretRecord(secret: secret, metadata: metadata(id: id, secretClass: secretClass))
    }

    public func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        try validate(id: id)
        guard secret.isEmpty == false else {
            throw LinuxSecretStoreError.missingSecret(id)
        }
        guard secret.contains("\0") == false,
              secret.contains("\n") == false,
              secret.contains("\r") == false else {
            throw LinuxSecretStoreError.invalidSecretValue(
                "native Secret Service and KWallet values must be a single line"
            )
        }
        guard secret.utf8.count <= 16_384 else {
            throw LinuxSecretStoreError.secretTooLarge(secret.utf8.count)
        }
        var input = Data((secret + "\n").utf8)
        defer { input.resetBytes(in: 0..<input.count) }
        let result = try execute(
            arguments: storeArguments(id: id, secretClass: secretClass),
            standardInput: input
        )
        guard result.exitCode == 0 else {
            throw commandError(operation: "store", result: result)
        }
        return metadata(id: id, secretClass: secretClass)
    }

    public func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
        try validate(id: id)
        let result = try execute(arguments: deleteArguments(id: id, secretClass: secretClass))
        guard result.exitCode == 0 || isMissing(result) else {
            throw commandError(operation: "delete", result: result)
        }
    }

    public func healthCheck() throws {
        let arguments: [String]
        switch kind {
        case .secretService:
            arguments = ["search", "openburnbar-health", "probe"]
        case .kwallet:
            arguments = ["-l", walletName]
        }
        let result = try execute(arguments: arguments)
        guard result.exitCode == 0 else {
            throw commandError(operation: "health-check", result: result)
        }
    }

    private func readArguments(id: String, secretClass: LinuxHighValueSecretClass) -> [String] {
        switch kind {
        case .secretService:
            ["lookup", "openburnbar-id", id, "openburnbar-class", secretClass.rawValue]
        case .kwallet:
            ["-f", folderName, "-r", id, walletName]
        }
    }

    private func storeArguments(id: String, secretClass: LinuxHighValueSecretClass) -> [String] {
        switch kind {
        case .secretService:
            [
                "store",
                "--label=OpenBurnBar \(secretClass.rawValue)",
                "openburnbar-id", id,
                "openburnbar-class", secretClass.rawValue
            ]
        case .kwallet:
            ["-f", folderName, "-w", id, walletName]
        }
    }

    private func deleteArguments(id: String, secretClass: LinuxHighValueSecretClass) -> [String] {
        switch kind {
        case .secretService:
            ["clear", "openburnbar-id", id, "openburnbar-class", secretClass.rawValue]
        case .kwallet:
            ["-f", folderName, "-d", id, walletName]
        }
    }

    private func execute(
        arguments: [String],
        standardInput: Data? = nil
    ) throws -> LinuxSecretCommandResult {
        do {
            return try runner(executableURL, arguments, standardInput)
        } catch let error as LinuxSecretStoreError {
            throw error
        } catch {
            throw LinuxSecretStoreError.backendUnavailable("\(backendName): \(error)")
        }
    }

    private func validate(id: String) throws {
        guard id.isEmpty == false,
              id.utf8.count <= 512,
              id.contains("\0") == false,
              id.contains("\n") == false,
              id.contains("\r") == false else {
            throw LinuxSecretStoreError.invalidSecretID(id)
        }
    }

    private func isMissing(_ result: LinuxSecretCommandResult) -> Bool {
        let detail = (result.stdout + "\n" + result.stderr).lowercased()
        return detail.contains("not found")
            || detail.contains("no such entry")
            || detail.contains("no matching")
    }

    private func commandError(
        operation: String,
        result: LinuxSecretCommandResult
    ) -> LinuxSecretStoreError {
        let detail = result.stderr
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedDetail = detail.isEmpty
            ? "exit \(result.exitCode)"
            : String(detail.prefix(256))
        return .commandFailed(backend: backendName, operation: operation, detail: boundedDetail)
    }

    private func metadata(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) -> LinuxSecretMetadata {
        LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: nowMillis(),
            note: "Secret held by \(backendName); only metadata may be logged."
        )
    }
}

public enum LinuxSecretStoreFactory {
    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        runner: @escaping LinuxSecretCommandRunner = LinuxSecretProcess.run
    ) -> LinuxSecretCustodian {
        var backends: [any LinuxSecretStoreBackend] = []
        let hasSessionBus = environment["DBUS_SESSION_BUS_ADDRESS"]?.trimmedNonEmpty != nil

        if hasSessionBus,
           let secretTool = executable(named: "secret-tool", environment: environment, fileManager: fileManager) {
            backends.append(
                LinuxNativeSecretStoreBackend(
                    kind: .secretService,
                    executableURL: secretTool,
                    runner: runner
                )
            )
        }
        if hasSessionBus,
           let kwallet = executable(named: "kwallet-query", environment: environment, fileManager: fileManager) {
            backends.append(
                LinuxNativeSecretStoreBackend(
                    kind: .kwallet,
                    executableURL: kwallet,
                    walletName: environment["OPENBURNBAR_KWALLET_NAME"]?.trimmedNonEmpty ?? "kdewallet",
                    runner: runner
                )
            )
        }

        backends.append(LinuxHeadlessSecretStoreBackend(environment: environment))
        return LinuxSecretCustodian(backends: backends)
    }

    private static func executable(
        named name: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        _ = environment
        for directory in ["/usr/bin", "/usr/local/bin", "/bin"] {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL
            var metadata = stat()
            guard lstat(candidate.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == 0,
                  metadata.st_mode & 0o022 == 0,
                  fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }
}

public enum LinuxSecretProcess {
    public static func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?
    ) throws -> LinuxSecretCommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = standardInput == nil ? nil : Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        if var standardInput, let stdin {
            defer { standardInput.resetBytes(in: 0..<standardInput.count) }
            try stdin.fileHandleForWriting.write(contentsOf: standardInput)
            try stdin.fileHandleForWriting.close()
        }
        let waiter = LinuxSecretProcessWaiter(process: process)
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            waiter.process.waitUntilExit()
            completion.signal()
        }
        if completion.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw LinuxSecretStoreError.backendUnavailable(
                "secret-store command timed out: \(executableURL.lastPathComponent)"
            )
        }
        let stdoutData = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderr.fileHandleForReading.readToEnd() ?? Data()
        return LinuxSecretCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}

private final class LinuxSecretProcessWaiter: @unchecked Sendable {
    let process: Process

    init(process: Process) {
        self.process = process
    }
}
