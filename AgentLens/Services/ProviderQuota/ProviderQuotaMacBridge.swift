import Foundation
import OpenBurnBarCore

// MARK: - macOS platform injections (WS-C2 / phase2 quota seam lift)

struct KeychainQuotaSecretStore: SecretStore {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore(
        service: OpenBurnBarCore.OpenBurnBarIdentity.cursorConnectorKeychainService,
        legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
    )) {
        self.keychain = keychain
    }

    func string(for account: String, service: String) -> String? {
        let store = KeychainStore(service: service, legacyServices: [])
        return store.credentialIfPresent(for: account, allowUserInteraction: false)
    }

    func setString(_ value: String, for account: String, service: String) throws {
        let store = KeychainStore(service: service, legacyServices: [])
        try store.set(value, for: account)
    }
}

struct ProcessQuotaCLIExecutor: CLIExecutor {
    func run(executable: String, arguments: [String], environment: [String: String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return stdout
        }
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw QuotaServiceError.invalidResponse(
            "CLI \(executable) exited \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    }
}

struct AppLoggerQuotaLogger: QuotaLogger {
    private static let shadowEvidence = MacDomainCoreShadowEvidenceRecorder()

    func log(_ message: String) {
        AppLogger.shared.error("quota_seam", metadata: ["message": message])
    }

    func recordDomainCoreShadowComparison(_ comparison: DomainCoreQuotaShadowComparison) {
        Self.shadowEvidence.record(comparison)
    }
}

enum ProviderQuotaMacPlatform {
    static let secretStore: any SecretStore = KeychainQuotaSecretStore()
    static let cliExecutor: any CLIExecutor = ProcessQuotaCLIExecutor()
    static let quotaLogger: any QuotaLogger = AppLoggerQuotaLogger()
}
