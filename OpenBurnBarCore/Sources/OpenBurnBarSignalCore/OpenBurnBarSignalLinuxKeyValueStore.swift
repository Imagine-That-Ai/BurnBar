#if !canImport(Security)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import OpenBurnBarCore

enum OpenBurnBarSignalLinuxKeyValueStore {
    struct Entry: Codable, Sendable {
        var dataBase64: String
        var metadata: [String: String]
    }

    static func read(
        service: String,
        account: String
    ) throws -> Data? {
        try readEntry(service: service, account: account)?.data
    }

    static func readEntry(
        service: String,
        account: String
    ) throws -> (data: Data, metadata: [String: String])? {
        let url = try entryURL(service: service, account: account, createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard let data = Data(base64Encoded: entry.dataBase64) else {
            throw CloudVaultCryptoError.keychainDataMissing
        }
        return (data, entry.metadata)
    }

    static func write(
        _ data: Data,
        service: String,
        account: String,
        metadata: [String: String] = [:]
    ) throws {
        let url = try entryURL(service: service, account: account, createDirectory: true)
        let entry = Entry(dataBase64: data.base64EncodedString(), metadata: metadata)
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete(service: String, account: String) throws {
        let url = try entryURL(service: service, account: account, createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func entryURL(
        service: String,
        account: String,
        createDirectory: Bool
    ) throws -> URL {
        let serviceDir = rootDirectory().appendingPathComponent(digestHex(service), isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: serviceDir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: serviceDir.path)
        }
        return serviceDir.appendingPathComponent("\(digestHex(account)).json", isDirectory: false)
    }

    private static func rootDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_SIGNAL_LINUX_STORE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/OpenBurnBar/signal-key-store", isDirectory: true)
    }

    private static func digestHex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
