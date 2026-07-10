import Foundation
import OpenBurnBarKernel

#if os(Linux)
import Glibc
#if canImport(COpenBurnBarSecretService)
import COpenBurnBarSecretService
#endif

enum LinuxPersistentSecretLoad: Equatable, Sendable {
    case found(Data)
    case absent
    case unreadable(Int32)
}

protocol LinuxSecretServiceClient: Sendable {
    func load(service: String, account: String) throws -> Data?
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

enum LinuxSecretServiceClientError: Error, Equatable {
    case unavailable(String)
}

struct UnavailableLinuxSecretServiceClient: LinuxSecretServiceClient {
    var reason: String

    func load(service _: String, account _: String) throws -> Data? {
        throw LinuxSecretServiceClientError.unavailable(reason)
    }

    func save(_: Data, service _: String, account _: String) throws {
        throw LinuxSecretServiceClientError.unavailable(reason)
    }

    func delete(service _: String, account _: String) throws {
        throw LinuxSecretServiceClientError.unavailable(reason)
    }
}

#if canImport(COpenBurnBarSecretService)
struct LibsecretLinuxSecretServiceClient: LinuxSecretServiceClient {
    func load(service: String, account: String) throws -> Data? {
        var out = OBBSecretBytes()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = service.withCString { servicePtr in
            account.withCString { accountPtr in
                obb_secret_service_lookup(servicePtr, accountPtr, &out, &errorMessage)
            }
        }
        defer {
            obb_secret_service_bytes_free(out)
            if let errorMessage {
                obb_secret_service_string_free(errorMessage)
            }
        }

        switch status {
        case 0:
            guard let bytes = out.bytes else { return Data() }
            return Data(bytes: bytes, count: out.length)
        case 1:
            return nil
        default:
            throw LinuxSecretServiceClientError.unavailable(Self.message(from: errorMessage))
        }
    }

    func save(_ data: Data, service: String, account: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = data.withUnsafeBytes { rawBuffer in
            service.withCString { servicePtr in
                account.withCString { accountPtr in
                    obb_secret_service_store(
                        servicePtr,
                        accountPtr,
                        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        rawBuffer.count,
                        &errorMessage
                    )
                }
            }
        }
        defer {
            if let errorMessage {
                obb_secret_service_string_free(errorMessage)
            }
        }
        guard status == 0 else {
            throw LinuxSecretServiceClientError.unavailable(Self.message(from: errorMessage))
        }
    }

    func delete(service: String, account: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = service.withCString { servicePtr in
            account.withCString { accountPtr in
                obb_secret_service_clear(servicePtr, accountPtr, &errorMessage)
            }
        }
        defer {
            if let errorMessage {
                obb_secret_service_string_free(errorMessage)
            }
        }
        guard status == 0 else {
            throw LinuxSecretServiceClientError.unavailable(Self.message(from: errorMessage))
        }
    }

    private static func message(from pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "libsecret operation failed" }
        return String(cString: pointer)
    }
}
#endif

final class LinuxPersistentSecretStore: Sendable {
    static let controllerPinService = "com.openburnbar.computeruse.controller-key-pin"
    static let irohHostPinService = "com.openburnbar.iroh.host-key-pin"
    static let remoteUnlockCapabilityService = "com.openburnbar.remote-unlock.capability-token-issuer"
    static let defaultRemoteUnlockCapabilityAccount = "default"

    private static let genericReadError: Int32 = -67671
    private static let genericWriteError: Int32 = -67672
    private static let genericDeleteError: Int32 = -67673

    private let service: String
    private let secretService: any LinuxSecretServiceClient
    private let fileStore: LinuxEncryptedFileSecretStore
    private let logger: @Sendable (String) -> Void

    init(
        service: String,
        fallbackDirectory: URL? = nil,
        secretService: (any LinuxSecretServiceClient)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: @escaping @Sendable (String) -> Void = LinuxPersistentSecretStore.defaultLogger
    ) {
        self.service = service
        #if canImport(COpenBurnBarSecretService)
        self.secretService = secretService ?? LibsecretLinuxSecretServiceClient()
        #else
        self.secretService = secretService ?? UnavailableLinuxSecretServiceClient(reason: "COpenBurnBarSecretService module unavailable")
        #endif
        self.fileStore = LinuxEncryptedFileSecretStore(
            rootDirectory: fallbackDirectory ?? Self.defaultFallbackDirectory(environment: environment)
        )
        self.logger = logger
    }

    func load(account: String) -> LinuxPersistentSecretLoad {
        do {
            if let data = try secretService.load(service: service, account: account) {
                return .found(data)
            }
        } catch {
            logFallback("Secret Service read failed for \(service)/\(account): \(error)")
            return fileStore.load(service: service, account: account)
        }

        let fileLoad = fileStore.load(service: service, account: account)
        if case .found = fileLoad {
            logFallback("Secret Service has no item for \(service)/\(account); using encrypted file fallback")
        }
        return fileLoad
    }

    @discardableResult
    func save(_ data: Data, account: String) -> Int32 {
        do {
            try secretService.save(data, service: service, account: account)
            // Write-through to the encrypted file store as a backup. Without
            // this, a pin saved while Secret Service is available lives ONLY in
            // Secret Service; a later headless daemon restart (no D-Bus session)
            // makes load() return .absent, which the pin store treats as first
            // contact and re-pins from the relay-advertised key — a remote
            // key-swap takeover. The backup keeps load() authoritative.
            if !fileStore.save(data, service: service, account: account) {
                logFallback("Secret Service write succeeded but encrypted file backup failed for \(service)/\(account)")
            }
            return errSecSuccessCompat
        } catch {
            logFallback("Secret Service write failed for \(service)/\(account): \(error)")
            return fileStore.save(data, service: service, account: account) ? errSecSuccessCompat : Self.genericWriteError
        }
    }

    func delete(account: String) {
        do {
            try secretService.delete(service: service, account: account)
        } catch {
            logFallback("Secret Service delete failed for \(service)/\(account): \(error)")
        }
        _ = fileStore.delete(service: service, account: account)
    }

    private func logFallback(_ message: String) {
        logger("OpenBurnBar Linux secrets: \(message); falling back to encrypted 0600 files")
    }

    private static func defaultFallbackDirectory(environment: [String: String]) -> URL {
        if let override = environment["OPENBURNBAR_LINUX_SECRET_STORE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let xdgDataHome = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgDataHome.isEmpty {
            return URL(fileURLWithPath: xdgDataHome, isDirectory: true)
                .appendingPathComponent("openburnbar/secrets", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/openburnbar/secrets", isDirectory: true)
    }

    private static func defaultLogger(_ message: String) {
        // Glibc imports stderr as a mutable global (not concurrency-safe under
        // Swift 6); FileHandle.standardError is Sendable on both platforms.
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

private final class LinuxEncryptedFileSecretStore: Sendable {
    private struct Envelope: Codable, Sendable {
        var schemaVersion: Int
        var service: String
        var account: String
        var sealedBase64: String
        var createdAtEpoch: Double
    }

    private static let schemaVersion = 1
    private static let fileKeyFileName = ".openburnbar-linux-secret-file-key-v1"
    private static let envelopeExtension = "obbsecret"
    // The file-encryption key is stored as raw bytes protected by 0600 perms + O_NOFOLLOW
    // (not AEAD-wrapped): there is no lower key-encryption-key to wrap it with
    // on a headless daemon. A TPM/keyring-derived KEK wrap is a named hardening
    // follow-up; not implementing it here avoids a false sense of authentication.
    private let rootDirectory: URL
    private let lock = NSLock()

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func load(service: String, account: String) -> LinuxPersistentSecretLoad {
        lock.lock()
        defer { lock.unlock() }

        let url = secretURL(service: service, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.service == service,
                  envelope.account == account,
                  let sealed = Data(base64Encoded: envelope.sealedBase64) else {
                return .unreadable(-67674)
            }
            let key = try loadOrCreateFileKey()
            let plaintext = try PlatformCrypto.openAESGCM(
                combined: sealed,
                keyData: key,
                authenticating: associatedData(service: service, account: account)
            )
            return .found(plaintext)
        } catch {
            return .unreadable(-67675)
        }
    }

    @discardableResult
    func save(_ data: Data, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            try prepareDirectory()
            let key = try loadOrCreateFileKey()
            let sealed = try PlatformCrypto.sealAESGCM(
                plaintext: data,
                keyData: key,
                authenticating: associatedData(service: service, account: account)
            )
            let envelope = Envelope(
                schemaVersion: Self.schemaVersion,
                service: service,
                account: account,
                sealedBase64: sealed.base64EncodedString(),
                createdAtEpoch: Date().timeIntervalSince1970
            )
            let encoded = try JSONEncoder().encode(envelope)
            try write0600(encoded, to: secretURL(service: service, account: account))
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = secretURL(service: service, account: account)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }

    private func loadOrCreateFileKey() throws -> Data {
        try prepareDirectory()
        let url = rootDirectory.appendingPathComponent(Self.fileKeyFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            let key = try Data(contentsOf: url)
            guard key.count == 32 else { throw LinuxSecretFileStoreError.invalidFileKey }
            return key
        }

        // Threat-model note: when freedesktop Secret Service is unavailable on
        // headless Linux, no OS-backed unwrap key exists. The fallback therefore
        // uses a machine-local random AES-256 key stored 0600 beside the sealed
        // records. This protects against accidental disclosure, backups, and
        // non-owner reads, but not against an attacker who can read the daemon
        // user's files. Secret Service remains the preferred production backend.
        let key = try PlatformCrypto.secureRandomBytes(count: 32)
        try write0600(key, to: url)
        return key
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try chmodPath(rootDirectory.path, mode: S_IRWXU)
    }

    private func secretURL(service: String, account: String) -> URL {
        let digest = PlatformCrypto.sha256Hex(Data("\(service)\u{0}\(account)".utf8))
        return rootDirectory.appendingPathComponent("\(digest).\(Self.envelopeExtension)", isDirectory: false)
    }

    private func associatedData(service: String, account: String) -> Data {
        Data("OpenBurnBar-LinuxSecretFile-v1|\(service)|\(account)".utf8)
    }

    private func write0600(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        let tempURL = rootDirectory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        try writeBytes(data, to: tempURL, mode: S_IRUSR | S_IWUSR)
        // Atomic replace via rename(2): overwrites the destination directory
        // entry in a single step, eliminating the remove-then-move TOCTOU
        // window. The temp file is already 0600 from writeBytes' fchmod, and
        // rename preserves the inode's mode, so no post-rename chmod is needed.
        let renamed = tempURL.path.withCString { src in
            url.path.withCString { dst in Glibc.rename(src, dst) }
        }
        guard renamed == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw LinuxSecretFileStoreError.posix(err)
        }
    }

    private func writeBytes(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = Glibc.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw LinuxSecretFileStoreError.posix(errno) }
        var shouldClose = true
        defer {
            if shouldClose {
                _ = Glibc.close(fd)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Glibc.write(fd, pointer, remaining)
                guard written >= 0 else { throw LinuxSecretFileStoreError.posix(errno) }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        if Glibc.fchmod(fd, mode) != 0 {
            throw LinuxSecretFileStoreError.posix(errno)
        }
        let closeStatus = Glibc.close(fd)
        shouldClose = false
        if closeStatus != 0 {
            throw LinuxSecretFileStoreError.posix(errno)
        }
    }

    private func chmodPath(_ path: String, mode: mode_t) throws {
        guard Glibc.chmod(path, mode) == 0 else {
            throw LinuxSecretFileStoreError.posix(errno)
        }
    }
}

private enum LinuxSecretFileStoreError: Error {
    case invalidFileKey
    case posix(Int32)
}

public final class LinuxSecretControllerKeyPinBacking: ControllerKeyPinBacking, Sendable {
    private let store: LinuxPersistentSecretStore

    public convenience init(service: String) {
        self.init(store: LinuxPersistentSecretStore(service: service))
    }

    init(
        service: String,
        fallbackDirectory: URL,
        secretService: any LinuxSecretServiceClient,
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = LinuxPersistentSecretStore(
            service: service,
            fallbackDirectory: fallbackDirectory,
            secretService: secretService,
            logger: logger
        )
    }

    init(store: LinuxPersistentSecretStore) {
        self.store = store
    }

    public func load(account: String) -> ControllerKeyPinLoad {
        switch store.load(account: account) {
        case .found(let data):
            guard let record = try? JSONDecoder().decode(ControllerPinRecord.self, from: data) else {
                return .unreadable(-67676)
            }
            return .found(record)
        case .absent:
            return .absent
        case .unreadable(let status):
            return .unreadable(status)
        }
    }

    @discardableResult
    public func save(_ record: ControllerPinRecord, account: String) -> Int32 {
        guard let data = try? JSONEncoder().encode(record) else { return -67677 }
        return store.save(data, account: account)
    }

    public func delete(account: String) {
        store.delete(account: account)
    }
}
#endif
