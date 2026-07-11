import Foundation
#if os(Linux)
import Glibc
#endif

public enum LinuxDesktopOwnerAuthenticationError: Error, Equatable, CustomStringConvertible, Sendable {
    case polkitUnavailable(String)
    case polkitDenied
    case pamUnavailable(String)
    case pamDenied
    case localAuthUnavailable(String)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case let .polkitUnavailable(reason):
            return "polkit unavailable: \(reason)"
        case .polkitDenied:
            return "Desktop-owner authorization was denied by polkit."
        case let .pamUnavailable(reason):
            return "PAM unavailable: \(reason)"
        case .pamDenied:
            return "Desktop-owner authorization was denied by PAM."
        case let .localAuthUnavailable(reason):
            return "Desktop-owner local authentication is unavailable: \(reason)"
        case .unsupportedPlatform:
            return "Desktop-owner local authentication is only available on Linux."
        }
    }
}

public struct LinuxDesktopOwnerAuthenticationProof: Codable, Equatable, Sendable {
    public var localAuthenticationSatisfied: Bool
    public var authority: String
    public var actionID: String
    public var authenticatedAtMillis: Int64
    public var reason: String

    public init(
        localAuthenticationSatisfied: Bool,
        authority: String,
        actionID: String,
        authenticatedAtMillis: Int64,
        reason: String
    ) {
        self.localAuthenticationSatisfied = localAuthenticationSatisfied
        self.authority = authority
        self.actionID = actionID
        self.authenticatedAtMillis = authenticatedAtMillis
        self.reason = reason
    }
}

public struct LinuxPolkitAuthorizationResult: Equatable, Sendable {
    public var isAuthorized: Bool
    public var isChallenge: Bool
    public var details: [String: String]

    public init(isAuthorized: Bool, isChallenge: Bool, details: [String: String] = [:]) {
        self.isAuthorized = isAuthorized
        self.isChallenge = isChallenge
        self.details = details
    }
}

public protocol LinuxPolkitAuthorizing: Sendable {
    func checkAuthorization(
        actionID: String,
        unixProcessID: Int32,
        allowUserInteraction: Bool
    ) async throws -> LinuxPolkitAuthorizationResult
}

public protocol LinuxPAMAuthenticating: Sendable {
    func authenticate(serviceName: String, reason: String) async throws -> Bool
}

public struct LinuxDesktopOwnerAuthenticator: Sendable {
    public static let computerUseGrantActionID = "com.openburnbar.computer-use.grant"
    public static let defaultPAMServiceName = "openburnbar"

    public var polkit: any LinuxPolkitAuthorizing
    public var pam: any LinuxPAMAuthenticating
    public var actionID: String
    public var pamServiceName: String
    public var processID: Int32
    public var nowMillis: @Sendable () -> Int64

    public init(
        polkit: any LinuxPolkitAuthorizing = LinuxPolkitDBusAuthority(),
        pam: any LinuxPAMAuthenticating = LinuxPAMSystemAuthenticator(),
        actionID: String = Self.computerUseGrantActionID,
        pamServiceName: String = Self.defaultPAMServiceName,
        processID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.polkit = polkit
        self.pam = pam
        self.actionID = actionID
        self.pamServiceName = pamServiceName
        self.processID = processID
        self.nowMillis = nowMillis
    }

    public func authenticate(reason: String) async throws -> LinuxDesktopOwnerAuthenticationProof {
        do {
            let result = try await polkit.checkAuthorization(
                actionID: actionID,
                unixProcessID: processID,
                allowUserInteraction: true
            )
            guard result.isAuthorized else {
                throw LinuxDesktopOwnerAuthenticationError.polkitDenied
            }
            return proof(authority: "polkit", reason: reason)
        } catch let error as LinuxDesktopOwnerAuthenticationError {
            switch error {
            case .polkitUnavailable:
                return try await authenticateWithPAM(reason: reason)
            case .polkitDenied:
                throw error
            case .pamUnavailable, .pamDenied, .localAuthUnavailable, .unsupportedPlatform:
                throw error
            }
        } catch {
            return try await authenticateWithPAM(reason: reason)
        }
    }

    private func authenticateWithPAM(reason: String) async throws -> LinuxDesktopOwnerAuthenticationProof {
        do {
            guard try await pam.authenticate(serviceName: pamServiceName, reason: reason) else {
                throw LinuxDesktopOwnerAuthenticationError.pamDenied
            }
            return proof(authority: "pam", reason: reason)
        } catch let error as LinuxDesktopOwnerAuthenticationError {
            switch error {
            case let .pamUnavailable(reason):
                throw LinuxDesktopOwnerAuthenticationError.localAuthUnavailable(reason)
            default:
                throw error
            }
        } catch {
            throw LinuxDesktopOwnerAuthenticationError.localAuthUnavailable(String(describing: error))
        }
    }

    private func proof(authority: String, reason: String) -> LinuxDesktopOwnerAuthenticationProof {
        LinuxDesktopOwnerAuthenticationProof(
            localAuthenticationSatisfied: true,
            authority: authority,
            actionID: actionID,
            authenticatedAtMillis: nowMillis(),
            reason: reason
        )
    }
}

public struct LinuxPolkitDBusAuthority: LinuxPolkitAuthorizing {
    public var busSocketPath: String
    public var uidProvider: @Sendable () -> UInt32
    public var processStartTimeProvider: @Sendable (Int32) -> UInt64?

    public init(
        busSocketPath: String = "/run/dbus/system_bus_socket",
        uidProvider: @escaping @Sendable () -> UInt32 = {
            #if os(Linux)
            return UInt32(getuid())
            #else
            return 0
            #endif
        },
        processStartTimeProvider: @escaping @Sendable (Int32) -> UInt64? = LinuxPolkitDBusAuthority.readLinuxProcessStartTime
    ) {
        self.busSocketPath = busSocketPath
        self.uidProvider = uidProvider
        self.processStartTimeProvider = processStartTimeProvider
    }

    public func checkAuthorization(
        actionID: String,
        unixProcessID: Int32,
        allowUserInteraction: Bool
    ) async throws -> LinuxPolkitAuthorizationResult {
        #if os(Linux)
        let startTime = processStartTimeProvider(unixProcessID) ?? 0
        return try await Task.detached {
            var client = LinuxDBusPolkitClient(socketPath: busSocketPath, uid: uidProvider())
            defer { client.close() }
            return try client.checkAuthorization(
                actionID: actionID,
                unixProcessID: unixProcessID,
                processStartTime: startTime,
                allowUserInteraction: allowUserInteraction
            )
        }.value
        #else
        throw LinuxDesktopOwnerAuthenticationError.unsupportedPlatform
        #endif
    }

    public static func readLinuxProcessStartTime(pid: Int32) -> UInt64? {
        #if os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let rightParen = stat.lastIndex(of: ")") else {
            return nil
        }
        let suffix = stat[stat.index(after: rightParen)...].split(separator: " ")
        guard suffix.count > 19 else { return nil }
        return UInt64(suffix[19])
        #else
        return nil
        #endif
    }
}

public struct LinuxPAMSystemAuthenticator: LinuxPAMAuthenticating {
    public var passwordProvider: (@Sendable (_ serviceName: String, _ reason: String) async throws -> String?)?

    public init(
        passwordProvider: (@Sendable (_ serviceName: String, _ reason: String) async throws -> String?)? = nil
    ) {
        self.passwordProvider = passwordProvider
    }

    public func authenticate(serviceName: String, reason: String) async throws -> Bool {
        #if os(Linux)
        guard let passwordProvider else {
            throw LinuxDesktopOwnerAuthenticationError.pamUnavailable("no PAM conversation secret provider is installed")
        }
        guard let password = try await passwordProvider(serviceName, reason), password.isEmpty == false else {
            throw LinuxDesktopOwnerAuthenticationError.pamDenied
        }
        return try LinuxPAMConversation.authenticate(
            serviceName: serviceName,
            username: LinuxPAMConversation.currentUsername(),
            password: password
        )
        #else
        throw LinuxDesktopOwnerAuthenticationError.unsupportedPlatform
        #endif
    }
}

#if os(Linux)
private enum LinuxDBusError: Error, CustomStringConvertible {
    case connect(String)
    case auth(String)
    case write(String)
    case read(String)
    case errorReply(String)
    case malformedReply

    var description: String {
        switch self {
        case let .connect(reason): return "connect: \(reason)"
        case let .auth(reason): return "auth: \(reason)"
        case let .write(reason): return "write: \(reason)"
        case let .read(reason): return "read: \(reason)"
        case let .errorReply(name): return "error reply: \(name)"
        case .malformedReply: return "malformed reply"
        }
    }
}

private struct LinuxDBusPolkitClient {
    private var fd: Int32 = -1
    private let socketPath: String
    private let uid: UInt32
    private var serial: UInt32 = 1

    init(socketPath: String, uid: UInt32) {
        self.socketPath = socketPath
        self.uid = uid
    }

    mutating func close() {
        if fd >= 0 {
            _ = Glibc.close(fd)
            fd = -1
        }
    }

    mutating func checkAuthorization(
        actionID: String,
        unixProcessID: Int32,
        processStartTime: UInt64,
        allowUserInteraction: Bool
    ) throws -> LinuxPolkitAuthorizationResult {
        try connect()
        try authenticate()
        _ = try call(
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            member: "Hello",
            destination: "org.freedesktop.DBus",
            signature: "",
            body: Data()
        )

        var body = LinuxDBusWriter()
        body.align(8)
        body.writeString("unix-process")
        body.writeDictStringVariant([
            "pid": .uint32(UInt32(unixProcessID)),
            "start-time": .uint64(processStartTime)
        ])
        body.writeString(actionID)
        body.writeDictStringString([:])
        body.writeUInt32(allowUserInteraction ? 1 : 0)
        body.writeString("")

        let reply = try call(
            path: "/org/freedesktop/PolicyKit1/Authority",
            interface: "org.freedesktop.PolicyKit1.Authority",
            member: "CheckAuthorization",
            destination: "org.freedesktop.PolicyKit1",
            signature: "(sa{sv})sa{ss}us",
            body: body.data
        )
        guard reply.messageType == 2 else {
            if let errorName = reply.errorName {
                if errorName.contains("NotAuthorized") || errorName.contains("Cancelled") {
                    throw LinuxDesktopOwnerAuthenticationError.polkitDenied
                }
                throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable(errorName)
            }
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("unexpected D-Bus reply")
        }
        return try LinuxDBusPolkitClient.parseAuthorizationResult(reply.body)
    }

    private mutating func connect() throws {
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable(String(cString: strerror(errno)))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxPath else {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("system bus path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            socketPath.withCString {
                rawBuffer.copyMemory(from: UnsafeRawBufferPointer(start: $0, count: socketPath.utf8.count + 1))
            }
        }
        let status = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable(String(cString: strerror(errno)))
        }
    }

    private func authenticate() throws {
        let uidHex = String(String(uid).utf8.map { String(format: "%02x", $0) }.joined())
        try writeASCII("\0AUTH EXTERNAL \(uidHex)\r\n")
        let authLine = try readAuthLine()
        guard authLine.hasPrefix("OK ") else {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("D-Bus EXTERNAL auth rejected")
        }
        try writeASCII("BEGIN\r\n")
    }

    private mutating func call(
        path: String,
        interface: String,
        member: String,
        destination: String,
        signature: String,
        body: Data
    ) throws -> LinuxDBusMessage {
        let messageSerial = serial
        serial += 1
        let message = LinuxDBusMessageBuilder.methodCall(
            serial: messageSerial,
            path: path,
            interface: interface,
            member: member,
            destination: destination,
            signature: signature,
            body: body
        )
        try writeAll(message)
        let reply = try readMessage()
        if reply.messageType == 3 {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable(reply.errorName ?? "D-Bus method error")
        }
        return reply
    }

    private func writeASCII(_ string: String) throws {
        try writeAll(Data(string.utf8))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < data.count {
                let rc = Glibc.write(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent)
                guard rc > 0 else {
                    throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable(String(cString: strerror(errno)))
                }
                sent += rc
            }
        }
    }

    private func readAuthLine() throws -> String {
        var bytes: [UInt8] = []
        var byte = UInt8(0)
        while true {
            let rc = Glibc.read(fd, &byte, 1)
            guard rc == 1 else {
                throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("D-Bus auth handshake closed")
            }
            if byte == UInt8(ascii: "\n") { break }
            if byte != UInt8(ascii: "\r") { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let rc = Glibc.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                guard rc > 0 else {
                    throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("D-Bus socket closed")
                }
                offset += rc
            }
        }
        return data
    }

    private func readMessage() throws -> LinuxDBusMessage {
        let fixed = try readExactly(16)
        guard fixed.count == 16, fixed[0] == UInt8(ascii: "l") else {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("unsupported D-Bus endian")
        }
        let messageType = fixed[1]
        let bodyLength = Int(fixed.readUInt32LE(at: 4))
        let headerFieldsLength = Int(fixed.readUInt32LE(at: 12))
        let paddedHeaderFieldsLength = headerFieldsLength.padded(to: 8)
        let fields = try readExactly(paddedHeaderFieldsLength)
        let body = try readExactly(bodyLength)
        return LinuxDBusMessage(
            messageType: messageType,
            errorName: LinuxDBusMessage.parseErrorName(fields.prefix(headerFieldsLength)),
            body: body
        )
    }

    private static func parseAuthorizationResult(_ data: Data) throws -> LinuxPolkitAuthorizationResult {
        guard data.count >= 16 else {
            throw LinuxDesktopOwnerAuthenticationError.polkitUnavailable("malformed polkit result")
        }
        var reader = LinuxDBusReader(data: data)
        reader.align(8)
        let authorized = try reader.readBool()
        let challenge = try reader.readBool()
        let details = try reader.readDictStringString()
        return LinuxPolkitAuthorizationResult(isAuthorized: authorized, isChallenge: challenge, details: details)
    }
}

private enum LinuxDBusVariantValue {
    case uint32(UInt32)
    case uint64(UInt64)
}

private struct LinuxDBusWriter {
    var data = Data()

    mutating func align(_ boundary: Int) {
        let padding = data.count.padding(to: boundary)
        if padding > 0 {
            data.append(contentsOf: repeatElement(0, count: padding))
        }
    }

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func writeUInt64(_ value: UInt64) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func writeString(_ value: String) {
        writeUInt32(UInt32(value.utf8.count))
        data.append(contentsOf: value.utf8)
        writeUInt8(0)
    }

    mutating func writeObjectPath(_ value: String) {
        writeString(value)
    }

    mutating func writeSignature(_ value: String) {
        writeUInt8(UInt8(value.utf8.count))
        data.append(contentsOf: value.utf8)
        writeUInt8(0)
    }

    mutating func writeVariantString(_ signature: String, writeValue: (inout LinuxDBusWriter) -> Void) {
        writeSignature(signature)
        align(signature.alignment)
        writeValue(&self)
    }

    mutating func writeDictStringVariant(_ values: [String: LinuxDBusVariantValue]) {
        var dict = LinuxDBusWriter()
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            dict.align(8)
            dict.writeString(key)
            switch value {
            case let .uint32(number):
                dict.writeVariantString("u") { $0.writeUInt32(number) }
            case let .uint64(number):
                dict.writeVariantString("t") { $0.writeUInt64(number) }
            }
        }
        align(4)
        writeUInt32(UInt32(dict.data.count))
        align(8)
        data.append(dict.data)
    }

    mutating func writeDictStringString(_ values: [String: String]) {
        var dict = LinuxDBusWriter()
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            dict.align(8)
            dict.writeString(key)
            dict.writeString(value)
        }
        align(4)
        writeUInt32(UInt32(dict.data.count))
        align(8)
        data.append(dict.data)
    }
}

private struct LinuxDBusMessageBuilder {
    static func methodCall(
        serial: UInt32,
        path: String,
        interface: String,
        member: String,
        destination: String,
        signature: String,
        body: Data
    ) -> Data {
        var fields = LinuxDBusWriter()
        fields.writeHeaderField(code: 1, signature: "o") { $0.writeObjectPath(path) }
        fields.writeHeaderField(code: 2, signature: "s") { $0.writeString(interface) }
        fields.writeHeaderField(code: 3, signature: "s") { $0.writeString(member) }
        fields.writeHeaderField(code: 6, signature: "s") { $0.writeString(destination) }
        if signature.isEmpty == false {
            fields.writeHeaderField(code: 8, signature: "g") { $0.writeSignature(signature) }
        }

        var message = Data()
        message.append(UInt8(ascii: "l"))
        message.append(1)
        message.append(0)
        message.append(1)
        message.appendUInt32LE(UInt32(body.count))
        message.appendUInt32LE(serial)
        message.appendUInt32LE(UInt32(fields.data.count))
        message.append(fields.data)
        message.appendPadding(to: 8)
        message.append(body)
        return message
    }
}

private extension LinuxDBusWriter {
    mutating func writeHeaderField(
        code: UInt8,
        signature: String,
        writeValue: (inout LinuxDBusWriter) -> Void
    ) {
        align(8)
        writeUInt8(code)
        writeVariantString(signature, writeValue: writeValue)
    }
}

private struct LinuxDBusMessage {
    var messageType: UInt8
    var errorName: String?
    var body: Data

    static func parseErrorName(_ fields: Data.SubSequence) -> String? {
        var reader = LinuxDBusReader(data: Data(fields))
        while reader.offset < reader.data.count {
            reader.align(8)
            guard let code = try? reader.readUInt8(), code == 4 else {
                _ = try? reader.skipVariant()
                continue
            }
            guard let signature = try? reader.readSignature(), signature == "s" else { return nil }
            reader.align(signature.alignment)
            return try? reader.readString()
        }
        return nil
    }
}

private struct LinuxDBusReader {
    var data: Data
    var offset: Int = 0

    mutating func align(_ boundary: Int) {
        offset += offset.padding(to: boundary)
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw LinuxDBusError.malformedReply }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw LinuxDBusError.malformedReply }
        defer { offset += 4 }
        return data.readUInt32LE(at: offset)
    }

    mutating func readBool() throws -> Bool {
        try readUInt32() != 0
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        guard offset + length + 1 <= data.count else { throw LinuxDBusError.malformedReply }
        let bytes = data[offset..<(offset + length)]
        offset += length + 1
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readSignature() throws -> String {
        let length = Int(try readUInt8())
        guard offset + length + 1 <= data.count else { throw LinuxDBusError.malformedReply }
        let bytes = data[offset..<(offset + length)]
        offset += length + 1
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readDictStringString() throws -> [String: String] {
        align(4)
        let byteLength = Int(try readUInt32())
        align(8)
        let end = offset + byteLength
        guard end <= data.count else { throw LinuxDBusError.malformedReply }
        var result: [String: String] = [:]
        while offset < end {
            align(8)
            let key = try readString()
            let value = try readString()
            result[key] = value
        }
        return result
    }

    mutating func skipVariant() throws {
        let signature = try readSignature()
        align(signature.alignment)
        switch signature {
        case "s", "o":
            _ = try readString()
        case "g":
            _ = try readSignature()
        case "u", "b":
            _ = try readUInt32()
        default:
            throw LinuxDBusError.malformedReply
        }
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendPadding(to boundary: Int) {
        let padding = count.padding(to: boundary)
        if padding > 0 {
            append(contentsOf: repeatElement(0, count: padding))
        }
    }
}

private extension Int {
    func padding(to boundary: Int) -> Int {
        let remainder = self % boundary
        return remainder == 0 ? 0 : boundary - remainder
    }

    func padded(to boundary: Int) -> Int {
        self + padding(to: boundary)
    }
}

private extension String {
    var alignment: Int {
        switch self {
        case "y", "g": return 1
        case "n", "q": return 2
        case "b", "i", "u", "h", "s", "o": return 4
        case "x", "t", "d", "(": return 8
        default:
            if hasPrefix("a") { return 4 }
            return 1
        }
    }
}

private typealias LinuxPAMHandle = OpaquePointer

private struct LinuxPAMMessage {
    var msg_style: Int32
    var msg: UnsafePointer<CChar>?
}

private struct LinuxPAMResponse {
    var resp: UnsafeMutablePointer<CChar>?
    var resp_retcode: Int32
}

private typealias LinuxPAMConvFunction = @convention(c) (
    Int32,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?
) -> Int32

private struct LinuxPAMConv {
    var conv: LinuxPAMConvFunction?
    var appdata_ptr: UnsafeMutableRawPointer?
}

@_silgen_name("pam_start")
private func pam_start(
    _ serviceName: UnsafePointer<CChar>,
    _ user: UnsafePointer<CChar>?,
    _ pamConversation: UnsafePointer<LinuxPAMConv>,
    _ pamh: UnsafeMutablePointer<LinuxPAMHandle?>
) -> Int32

@_silgen_name("pam_authenticate")
private func pam_authenticate(_ pamh: LinuxPAMHandle?, _ flags: Int32) -> Int32

@_silgen_name("pam_acct_mgmt")
private func pam_acct_mgmt(_ pamh: LinuxPAMHandle?, _ flags: Int32) -> Int32

@_silgen_name("pam_end")
private func pam_end(_ pamh: LinuxPAMHandle?, _ status: Int32) -> Int32

private enum LinuxPAMConversation {
    static func currentUsername() -> String? {
        guard let name = getpwuid(getuid())?.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    static func authenticate(serviceName: String, username: String?, password: String) throws -> Bool {
        var passwordBytes = Array(password.utf8CString)
        return passwordBytes.withUnsafeMutableBufferPointer { passwordBuffer in
            var conv = LinuxPAMConv(
                conv: { count, messages, responses, appData in
                    guard count >= 0, let messages, let responses, let appData else { return 7 }
                    let messagePointers = messages.assumingMemoryBound(to: UnsafePointer<LinuxPAMMessage>?.self)
                    let responsePointer = responses.assumingMemoryBound(to: UnsafeMutablePointer<LinuxPAMResponse>?.self)
                    let password = appData.assumingMemoryBound(to: CChar.self)
                    let allocated = calloc(Int(count), MemoryLayout<LinuxPAMResponse>.stride)
                        .assumingMemoryBound(to: LinuxPAMResponse.self)
                    for index in 0..<Int(count) {
                        guard let message = messagePointers[index] else {
                            allocated[index] = LinuxPAMResponse(resp: nil, resp_retcode: 0)
                            continue
                        }
                        switch message.pointee.msg_style {
                        case 1, 2:
                            allocated[index] = LinuxPAMResponse(resp: strdup(password), resp_retcode: 0)
                        default:
                            allocated[index] = LinuxPAMResponse(resp: nil, resp_retcode: 0)
                        }
                    }
                    responsePointer.pointee = allocated
                    return 0
                },
                appdata_ptr: passwordBuffer.baseAddress
            )
            var handle: LinuxPAMHandle?
            var finalStatus: Int32 = 0
            defer {
                if let handle {
                    _ = pam_end(handle, finalStatus)
                }
                if let baseAddress = passwordBuffer.baseAddress {
                    memset(baseAddress, 0, passwordBuffer.count)
                }
            }
            let startStatus = serviceName.withCString { servicePointer in
                username.withOptionalCString { userPointer in
                    pam_start(servicePointer, userPointer, &conv, &handle)
                }
            }
            guard startStatus == 0 else { return false }
            finalStatus = startStatus
            finalStatus = pam_authenticate(handle, 0)
            guard finalStatus == 0 else { return false }
            finalStatus = pam_acct_mgmt(handle, 0)
            return finalStatus == 0
        }
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        switch self {
        case let .some(value):
            return value.withCString(body)
        case .none:
            return body(nil)
        }
    }
}
#endif
