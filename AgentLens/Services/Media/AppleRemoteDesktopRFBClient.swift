import CommonCrypto
import CryptoKit
import Foundation
import os
import Security

#if canImport(Darwin)
import Darwin
#endif

/// Minimal Apple Screen Sharing / ARD loopback client used for Remote Unlock.
///
/// ScreenCaptureKit belongs to the logged-in user session, so it stops being a
/// reliable capture/control lane once loginwindow owns the display. Apple's own
/// Screen Sharing service keeps a system-level loginwindow lane alive. This
/// client authenticates to that local service using ARD security type 30 and
/// sends RFB keyboard events through it, which is the same class of input a
/// real Screen Sharing session uses at the lock screen.
final class AppleRemoteDesktopRFBClient: Sendable {
    enum Failure: Error, Equatable {
        case socketUnavailable
        case connectFailed
        case readFailed
        case writeFailed
        case protocolMismatch(String)
        case appleARDAuthUnavailable([UInt8])
        case cryptographyFailed
        case authenticationRejected(String?)
        case unsupportedPasswordScalar
    }

    struct Credentials: Sendable, Equatable {
        var username: String
        var password: String

        init(username: String = NSUserName(), password: String) {
            self.username = username
            self.password = password
        }
    }

    static let log = Logger(subsystem: "com.openburnbar.app", category: "RemoteUnlock")

    private let host: String
    private let port: UInt16
    private let timeoutSeconds: Int32

    init(
        host: String = "127.0.0.1",
        port: UInt16 = 5900,
        timeoutSeconds: Int32 = 8
    ) {
        self.host = host
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }

    /// Blocking RFB socket work runs off the main actor: this is a `nonisolated`
    /// `async` method (the type is `Sendable`, not actor-bound), so callers leave
    /// the main actor at the `await` (SE-0338).
    func typeCredential(_ credentials: Credentials) async throws {
        var stream = try RFBStream(host: host, port: port, timeoutSeconds: timeoutSeconds)
        defer { stream.close() }

        try Self.performHandshake(stream: &stream, credentials: credentials)
        let server = try Self.readServerInit(stream: &stream)

        try Self.focusLoginPasswordLane(stream: &stream, server: server)
        try Self.sendText(credentials.password, stream: &stream)
        usleep(90_000)
        try Self.sendKey(stream: &stream, keysym: RFBKeysym.returnKey)
    }

    private static func performHandshake(stream: inout RFBStream, credentials: Credentials) throws {
        let banner = try stream.readExact(byteCount: 12)
        guard let bannerString = String(data: banner, encoding: .ascii),
              bannerString.hasPrefix("RFB ") else {
            throw Failure.protocolMismatch("missing_rfb_banner")
        }

        try stream.write(Data("RFB 003.889\n".utf8))
        let securityCount = try stream.readExact(byteCount: 1)[0]
        guard securityCount > 0 else {
            let reason = try? readReason(stream: &stream)
            throw Failure.protocolMismatch(reason ?? "empty_security_type_list")
        }

        let securityTypes = [UInt8](try stream.readExact(byteCount: Int(securityCount)))

        guard securityTypes.contains(RFBSecurityType.appleARD) else {
            throw Failure.appleARDAuthUnavailable(securityTypes)
        }
        Self.log.info("remote_unlock_ard_auth method=apple_ard offered=\(securityTypes.map(String.init).joined(separator: ","), privacy: .public)")
        try stream.write(Data([RFBSecurityType.appleARD]))
        try authenticateAppleARD(stream: &stream, credentials: credentials)
    }

    private static func authenticateAppleARD(
        stream: inout RFBStream,
        credentials: Credentials
    ) throws {
        let generatorBytes = try stream.readExact(byteCount: 2)
        let keyLengthBytes = try stream.readExact(byteCount: 2)
        let keyLength = Int(UInt16(keyLengthBytes[0]) << 8 | UInt16(keyLengthBytes[1]))
        guard keyLength > 0, keyLength <= 512 else {
            throw Failure.protocolMismatch("invalid_ard_key_length")
        }

        let modulusBytes = try stream.readExact(byteCount: keyLength)
        let serverPublicBytes = try stream.readExact(byteCount: keyLength)
        let generator = RemoteUnlockBigUInt(bigEndian: generatorBytes)
        let modulus = RemoteUnlockBigUInt(bigEndian: modulusBytes)
        let serverPublic = RemoteUnlockBigUInt(bigEndian: serverPublicBytes)

        var privateBytes = Data(count: keyLength)
        let randomStatus = privateBytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, keyLength, buffer.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw Failure.cryptographyFailed }
        if privateBytes.allSatisfy({ $0 == 0 }) {
            privateBytes[keyLength - 1] = 1
        }
        let privateKey = RemoteUnlockBigUInt(bigEndian: privateBytes)
        let publicKey = RemoteUnlockBigUInt.powMod(base: generator, exponent: privateKey, modulus: modulus)
        let sharedKey = RemoteUnlockBigUInt.powMod(base: serverPublic, exponent: privateKey, modulus: modulus)
        let sharedBytes = sharedKey.bigEndianData(byteCount: keyLength)
        let aesKey = Data(Insecure.MD5.hash(data: sharedBytes))
        let credentialBlock = try credentialBlock(username: credentials.username, password: credentials.password)
        let ciphertext = try aes128ECBEncrypt(credentialBlock, key: aesKey)

        try stream.write(ciphertext)
        try stream.write(publicKey.bigEndianData(byteCount: keyLength))

        let resultData = try stream.readExact(byteCount: 4)
        let result = resultData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard result == 0 else {
            throw Failure.authenticationRejected(try? readReason(stream: &stream))
        }
    }

    private static func credentialBlock(username: String, password: String) throws -> Data {
        var block = Data(count: 128)
        let randomStatus = block.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 128, buffer.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw Failure.cryptographyFailed }
        writeCString(username, into: &block, range: 0..<64)
        writeCString(password, into: &block, range: 64..<128)
        return block
    }

    private static func writeCString(_ string: String, into data: inout Data, range: Range<Int>) {
        let bytes = Array(string.utf8.prefix(max(0, range.count - 1)))
        data.replaceSubrange(range.lowerBound..<(range.lowerBound + bytes.count), with: bytes)
        data[range.lowerBound + bytes.count] = 0
    }

    private static func aes128ECBEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw Failure.cryptographyFailed }
        let outputCapacity = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var bytesWritten = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            plaintext.withUnsafeBytes { plaintextBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        plaintextBuffer.baseAddress,
                        plaintext.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &bytesWritten
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.cryptographyFailed }
        output.removeSubrange(bytesWritten..<output.count)
        return output
    }

    private static func readServerInit(stream: inout RFBStream) throws -> RFBServerInit {
        try stream.write(Data([1])) // shared ClientInit
        let header = try stream.readExact(byteCount: 24)
        let width = Int(UInt16(header[0]) << 8 | UInt16(header[1]))
        let height = Int(UInt16(header[2]) << 8 | UInt16(header[3]))
        let nameLength = Int(
            UInt32(header[20]) << 24 |
            UInt32(header[21]) << 16 |
            UInt32(header[22]) << 8 |
            UInt32(header[23])
        )
        if nameLength > 0 {
            _ = try stream.readExact(byteCount: nameLength)
        }
        return RFBServerInit(width: width, height: height)
    }

    private static func sendText(_ text: String, stream: inout RFBStream) throws {
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0x10FFFF else { throw Failure.unsupportedPasswordScalar }
            try sendKey(stream: &stream, keysym: UInt32(scalar.value))
            usleep(32_000)
        }
    }

    private static func focusLoginPasswordLane(stream: inout RFBStream, server: RFBServerInit) throws {
        let centerX = server.width / 2
        let centerY = server.height / 2
        let candidateRows = [
            centerY,
            Int(Double(server.height) * 0.56),
            Int(Double(server.height) * 0.63)
        ]

        // Apple Screen Sharing receives these events even when ScreenCaptureKit
        // and normal CGEvents cannot see loginwindow. The lock screen may need
        // a wake, an account selection, and a "type password" reveal before the
        // password field accepts text, so do a deliberately paced focus pass.
        try sendKey(stream: &stream, keysym: RFBKeysym.escape)
        usleep(250_000)
        try sendKey(stream: &stream, keysym: RFBKeysym.returnKey)
        usleep(450_000)

        for row in candidateRows {
            try sendPointerClick(stream: &stream, x: centerX, y: row)
            usleep(350_000)
            try sendKey(stream: &stream, keysym: RFBKeysym.space)
            usleep(450_000)
            try sendKey(stream: &stream, keysym: RFBKeysym.backspace)
            usleep(300_000)
        }
    }

    private static func sendKey(stream: inout RFBStream, keysym: UInt32) throws {
        try stream.write(makeKeyEventMessage(keysym: keysym, down: true))
        try stream.write(makeKeyEventMessage(keysym: keysym, down: false))
    }

    static func makeKeyEventMessage(keysym: UInt32, down: Bool) -> Data {
        var data = Data([4, down ? 1 : 0, 0, 0])
        data.append(UInt8((keysym >> 24) & 0xff))
        data.append(UInt8((keysym >> 16) & 0xff))
        data.append(UInt8((keysym >> 8) & 0xff))
        data.append(UInt8(keysym & 0xff))
        return data
    }

    private static func sendPointerClick(stream: inout RFBStream, x: Int, y: Int, button: Int = 0) throws {
        let clampedX = UInt16(max(0, min(Int(UInt16.max), x)))
        let clampedY = UInt16(max(0, min(Int(UInt16.max), y)))
        let mask: UInt8 = button == 1 ? 4 : button == 2 ? 2 : 1
        try stream.write(makePointerEventMessage(buttonMask: mask, x: clampedX, y: clampedY))
        try stream.write(makePointerEventMessage(buttonMask: 0, x: clampedX, y: clampedY))
    }

    static func makePointerEventMessage(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        Data([
            5,
            buttonMask,
            UInt8((x >> 8) & 0xff),
            UInt8(x & 0xff),
            UInt8((y >> 8) & 0xff),
            UInt8(y & 0xff)
        ])
    }

    private static func readReason(stream: inout RFBStream) throws -> String {
        let lengthData = try stream.readExact(byteCount: 4)
        let length = Int(
            UInt32(lengthData[0]) << 24 |
            UInt32(lengthData[1]) << 16 |
            UInt32(lengthData[2]) << 8 |
            UInt32(lengthData[3])
        )
        guard length > 0, length < 4096 else { return "invalid_reason" }
        return String(data: try stream.readExact(byteCount: length), encoding: .utf8) ?? "unreadable_reason"
    }
}

private enum RFBSecurityType {
    static let appleARD: UInt8 = 30
}

private enum RFBKeysym {
    static let backspace: UInt32 = 0xff08
    static let escape: UInt32 = 0xff1b
    static let returnKey: UInt32 = 0xff0d
    static let shiftLeft: UInt32 = 0xffe1
    static let space: UInt32 = 0x20
}

private struct RFBServerInit {
    var width: Int
    var height: Int
}

#if canImport(Darwin)
private struct RFBStream {
    private var fd: Int32 = -1

    init(host: String, port: UInt16, timeoutSeconds: Int32) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppleRemoteDesktopRFBClient.Failure.socketUnavailable }
        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close()
            throw AppleRemoteDesktopRFBClient.Failure.connectFailed
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close()
            throw AppleRemoteDesktopRFBClient.Failure.connectFailed
        }
    }

    mutating func readExact(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < byteCount {
                let count = Darwin.read(fd, base.advanced(by: offset), byteCount - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count == 0 { throw AppleRemoteDesktopRFBClient.Failure.readFailed }
                if errno == EINTR { continue }
                throw AppleRemoteDesktopRFBClient.Failure.readFailed
            }
        }
        return data
    }

    mutating func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if errno == EINTR { continue }
                throw AppleRemoteDesktopRFBClient.Failure.writeFailed
            }
        }
    }

    mutating func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
#endif

struct RemoteUnlockBigUInt: Equatable, Sendable {
    private var limbs: [UInt32]

    init(_ value: UInt32) {
        self.limbs = value == 0 ? [] : [value]
    }

    init(bigEndian data: Data) {
        var limbs: [UInt32] = []
        var index = data.count
        while index > 0 {
            let start = max(0, index - 4)
            var limb: UInt32 = 0
            for byte in data[start..<index] {
                limb = (limb << 8) | UInt32(byte)
            }
            limbs.append(limb)
            index = start
        }
        self.limbs = limbs
        normalize()
    }

    func bigEndianData(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(byteCount, 0))
        var outputIndex = bytes.count
        for limb in limbs {
            var value = limb
            for _ in 0..<4 where outputIndex > 0 {
                outputIndex -= 1
                bytes[outputIndex] = UInt8(value & 0xff)
                value >>= 8
            }
        }
        return Data(bytes)
    }

    static func powMod(base: RemoteUnlockBigUInt, exponent: RemoteUnlockBigUInt, modulus: RemoteUnlockBigUInt) -> RemoteUnlockBigUInt {
        guard !modulus.isZero else { return RemoteUnlockBigUInt(0) }
        var result = RemoteUnlockBigUInt(1)
        let base = modReduce(base, modulus: modulus)
        let exponentBytes = exponent.bigEndianData(byteCount: max(1, exponent.limbs.count * 4))
        for byte in exponentBytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = mulMod(result, result, modulus: modulus)
                if ((byte >> UInt8(bit)) & 1) == 1 {
                    result = mulMod(result, base, modulus: modulus)
                }
            }
        }
        return result
    }

    private var isZero: Bool { limbs.isEmpty }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    private var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private func shiftedLeft(byBits n: Int) -> RemoteUnlockBigUInt {
        if isZero || n == 0 { return self }
        let limbShift = n / 32
        let bitShift = n % 32
        var output = [UInt32](repeating: 0, count: limbs.count + limbShift + 1)
        for index in 0..<limbs.count {
            let value = UInt64(limbs[index]) << UInt64(bitShift)
            output[index + limbShift] |= UInt32(value & 0xffff_ffff)
            output[index + limbShift + 1] |= UInt32(value >> 32)
        }
        return RemoteUnlockBigUInt(limbs: output)
    }

    private func shiftedRightOne() -> RemoteUnlockBigUInt {
        guard !limbs.isEmpty else { return self }
        var output = limbs
        var carry: UInt32 = 0
        for index in stride(from: output.count - 1, through: 0, by: -1) {
            let nextCarry = output[index] & 1
            output[index] = (output[index] >> 1) | (carry << 31)
            carry = nextCarry
        }
        return RemoteUnlockBigUInt(limbs: output)
    }

    /// Full (non-modular) product via schoolbook word multiplication — O(n²) limb multiplies
    /// instead of the previous O(bits) shift-and-add, which made the 1024-bit ARD Diffie-Hellman
    /// take ~13s per `powMod` (~27s total) and miss the login-window's wake/timing window.
    private static func multiplyFull(_ lhs: RemoteUnlockBigUInt, _ rhs: RemoteUnlockBigUInt) -> RemoteUnlockBigUInt {
        if lhs.isZero || rhs.isZero { return RemoteUnlockBigUInt(0) }
        var output = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let lhsLimb = UInt64(lhs.limbs[i])
            for j in 0..<rhs.limbs.count {
                let term = lhsLimb * UInt64(rhs.limbs[j]) + UInt64(output[i + j]) + carry
                output[i + j] = UInt32(term & 0xffff_ffff)
                carry = term >> 32
            }
            output[i + rhs.limbs.count] = UInt32(carry)
        }
        return RemoteUnlockBigUInt(limbs: output)
    }

    /// `value mod modulus` via binary long division. `modulus` must be non-zero. One conditional
    /// subtraction per bit position keeps each step O(limbs); never the unbounded subtract loop.
    private static func modReduce(_ value: RemoteUnlockBigUInt, modulus: RemoteUnlockBigUInt) -> RemoteUnlockBigUInt {
        if value < modulus { return value }
        let modulusBits = modulus.bitLength
        var remainder = value
        var shift = remainder.bitLength - modulusBits
        if shift < 0 { return remainder }
        var shifted = modulus.shiftedLeft(byBits: shift)
        while true {
            if !(remainder < shifted) {
                remainder = subtract(remainder, shifted)
            }
            if shift == 0 { break }
            shifted = shifted.shiftedRightOne()
            shift -= 1
        }
        return remainder
    }

    private static func mulMod(
        _ lhs: RemoteUnlockBigUInt,
        _ rhs: RemoteUnlockBigUInt,
        modulus: RemoteUnlockBigUInt
    ) -> RemoteUnlockBigUInt {
        modReduce(multiplyFull(lhs, rhs), modulus: modulus)
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    private static func subtract(_ lhs: RemoteUnlockBigUInt, _ rhs: RemoteUnlockBigUInt) -> RemoteUnlockBigUInt {
        var limbs = lhs.limbs
        var borrow: Int64 = 0
        for index in 0..<limbs.count {
            let value = Int64(limbs[index]) - Int64(rhs.limbs[safe: index] ?? 0) - borrow
            if value < 0 {
                limbs[index] = UInt32(value + Int64(UInt64(1) << 32))
                borrow = 1
            } else {
                limbs[index] = UInt32(value)
                borrow = 0
            }
        }
        return RemoteUnlockBigUInt(limbs: limbs)
    }
}

extension RemoteUnlockBigUInt: Comparable {
    static func < (lhs: RemoteUnlockBigUInt, rhs: RemoteUnlockBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        guard !lhs.limbs.isEmpty else { return false }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
