import Foundation
import SQLite3
import CommonCrypto
import Security

// MARK: - Factory Cookie Auto-Extractor

/// Reads Factory session cookies from browser cookie stores.
///
/// Resolution order (first wins):
/// 1. Chrome cookies (decrypted via keychain + PBKDF2 + AES-CBC)
/// 2. Safari binarycookies (needs Full Disk Access)
///
/// Chrome cookie decryption follows the same algorithm as `browser_cookie3`:
/// - Keychain item: "Chrome Safe Storage" (account: "Chrome")
/// - PBKDF2(password, salt="saltysalt", 16 bytes, 1003 iterations)
/// - AES-128-CBC with IV = 16 spaces
/// - Skip 32-byte integrity prefix
///
/// Reference: browser_cookie3 (github.com/borisbabic/browser_cookie3)
/// Verified working on 2026-05-02 — successfully decrypted all 6 factory.ai cookies.

enum FactoryCookieExtractor {

    // MARK: - Public API

    /// Reads Factory cookies from available browser stores.
    /// Returns a cookie header string suitable for the `Cookie` HTTP header.
    static func extractCookieHeader() -> String? {
        if let chromeCookies = extractChromeCookies() {
            return chromeCookies
        }
        if let safariCookies = extractSafariCookies() {
            return safariCookies
        }
        return nil
    }

    /// Extracts the `access-token` value from a cookie header.
    /// Can be used as a Bearer token for Factory API calls.
    static func extractBearerToken(from cookieHeader: String) -> String? {
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == "access-token" else { continue }
            let value = parts[1]
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Chrome Cookie Extraction

    private static func extractChromeCookies() -> String? {
        // Scan all Chrome profiles (Default, Profile 1, Profile 2, ...)
        let chromeBase = ("~/Library/Application Support/Google/Chrome" as NSString).expandingTildeInPath
        var chromeProfiles: [String] = []
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: chromeBase) {
            for item in contents {
                let cookiesPath = "\(chromeBase)/\(item)/Cookies"
                if FileManager.default.fileExists(atPath: cookiesPath) {
                    chromeProfiles.append(cookiesPath)
                }
            }
        }
        // Sort so Default comes first
        chromeProfiles.sort { a, b in
            if a.contains("/Default/") { return true }
            if b.contains("/Default/") { return false }
            return a < b
        }

        // Get the decryption key from the keychain
        guard let encryptionKey = deriveChromeEncryptionKey() else {
            return nil
        }

        for profilePath in chromeProfiles {
            guard FileManager.default.fileExists(atPath: profilePath) else { continue }
            guard let cookies = readAndDecryptChromeCookies(
                dbPath: profilePath,
                key: encryptionKey
            ) else { continue }

            let factoryCookies = cookies.filter { $0.name == "access-token" || $0.name == "__recent_auth" || $0.domain.contains("factory.ai") }
            guard !factoryCookies.isEmpty else { continue }

            let header = factoryCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            guard !header.isEmpty else { continue }
            return header
        }

        return nil
    }

    // MARK: - Chrome Key Derivation

    /// Derives the AES-128 key from the Chrome Safe Storage keychain item.
    ///
    /// Algorithm:
    /// 1. Read password from keychain (service: "Chrome Safe Storage", account: "Chrome")
    /// 2. PBKDF2-HMAC-SHA1 with salt "saltysalt", 16 bytes output, 1003 iterations
    private static func deriveChromeEncryptionKey() -> Data? {
        // Read keychain password
        let service = "Chrome Safe Storage"
        let account = "Chrome"

        var passwordLength: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?

        let status = SecKeychainFindGenericPassword(
            nil,
            UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account,
            &passwordLength, &passwordData, nil
        )

        guard status == errSecSuccess, let data = passwordData, passwordLength > 0 else {
            return nil
        }

        defer { SecKeychainItemFreeContent(nil, data) }

        let password = Data(bytes: data, count: Int(passwordLength))

        // PBKDF2 key derivation
        let salt = "saltysalt".data(using: .utf8)!
        let iterations: UInt32 = 1003
        let keyLength = 16
        var derivedKey = Data(count: keyLength)

        let result = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derivedKey.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else { return nil }
        return derivedKey
    }

    // MARK: - Chrome Cookie Decryption

    private struct ChromeCookie {
        let domain: String
        let name: String
        let value: String
    }

    private static func readAndDecryptChromeCookies(
        dbPath: String,
        key: Data
    ) -> [ChromeCookie]? {
        guard let db = openDatabase(at: dbPath) else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT host_key, name, encrypted_value
            FROM cookies
            WHERE host_key LIKE '%factory.ai%'
            ORDER BY host_key, name
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var cookies: [ChromeCookie] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostCStr = sqlite3_column_text(stmt, 0),
                  let nameCStr = sqlite3_column_text(stmt, 1) else {
                continue
            }

            let host = String(cString: hostCStr)
            let name = String(cString: nameCStr)

            // Read encrypted_value blob
            guard let encBytes = sqlite3_column_blob(stmt, 2) else { continue }
            let encLength = Int(sqlite3_column_bytes(stmt, 2))
            let encryptedData = Data(bytes: encBytes, count: encLength)

            // Must start with "v10"
            guard encryptedData.count > 3,
                  encryptedData.prefix(3) == Data([0x76, 0x31, 0x30]) else {
                continue
            }

            let ciphertext = encryptedData.subdata(in: 3..<encryptedData.count)

            // AES-128-CBC decrypt with IV = 16 spaces
            guard let decrypted = aesCBCDecrypt(data: ciphertext, key: key) else {
                continue
            }

            // Skip 32-byte integrity prefix
            guard decrypted.count > 32 else { continue }
            let cookieValue = decrypted.subdata(in: 32..<decrypted.count)

            guard let value = String(data: cookieValue, encoding: .utf8) else {
                continue
            }

            cookies.append(ChromeCookie(domain: host, name: name, value: value))
        }

        return cookies.isEmpty ? nil : cookies
    }

    // MARK: - AES-128-CBC Decryption

    private static func aesCBCDecrypt(data: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: 16) // 16 spaces

        var outLength = data.count + kCCBlockSizeAES128
        var outData = Data(count: outLength)
        var actualLength = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    outData.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            outLength,
                            &actualLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return outData.prefix(actualLength)
    }

    // MARK: - SQLite Helpers

    private static func openDatabase(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    // MARK: - Safari Cookie Extraction (fallback)

    private static func extractSafariCookies() -> String? {
        let cookiePaths = [
            ("~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies" as NSString).expandingTildeInPath,
            ("~/Library/Cookies/Cookies.binarycookies" as NSString).expandingTildeInPath,
        ]

        for path in cookiePaths {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let cookies = parseSafariBinaryCookies(data) else {
                continue
            }

            let factoryCookies = cookies.filter { $0.domain.hasSuffix("factory.ai") }
            guard !factoryCookies.isEmpty else { continue }

            let header = factoryCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            guard !header.isEmpty else { continue }
            return header
        }

        return nil
    }

    // MARK: - Safari Binary Cookies Parser

    private struct ParsedCookie {
        let domain: String
        let name: String
        let value: String
    }

    private static func parseSafariBinaryCookies(_ data: Data) -> [ParsedCookie]? {
        guard data.count >= 8 else { return nil }
        let magic = data.prefix(4)
        guard magic == Data([0x63, 0x6F, 0x6F, 0x6B]) else { return nil }

        let pageCount = Int(readBigEndianUInt32(data, at: 4))
        var cookies: [ParsedCookie] = []
        var offset = 8

        for _ in 0..<pageCount {
            guard offset + 4 <= data.count else { break }
            let pageSize = Int(readBigEndianUInt32(data, at: offset))
            offset += 4
            let pageEnd = min(offset + pageSize, data.count)

            while offset + 8 <= pageEnd {
                let cookieSize = Int(readLittleEndianUInt32(data, at: offset))
                guard cookieSize > 0, offset + cookieSize <= pageEnd else { break }

                let urlOffset = Int(readLittleEndianUInt32(data, at: offset + 16))
                let nameOffset = Int(readLittleEndianUInt32(data, at: offset + 20))
                let valueOffset = Int(readLittleEndianUInt32(data, at: offset + 28))
                let recordEnd = offset + cookieSize

                let urlStr = readNullTerminatedString(data, from: offset + urlOffset, maxLength: recordEnd - (offset + urlOffset))
                let nameStr = readNullTerminatedString(data, from: offset + nameOffset, maxLength: recordEnd - (offset + nameOffset))
                let valueStr = readNullTerminatedString(data, from: offset + valueOffset, maxLength: recordEnd - (offset + valueOffset))

                if let url = urlStr,
                   let host = URL(string: "http://\(url.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: ""))")?.host,
                   let name = nameStr, !name.isEmpty,
                   let value = valueStr, !value.isEmpty {
                    cookies.append(ParsedCookie(domain: host, name: name, value: value))
                }

                offset += cookieSize
            }
            offset = pageEnd
        }

        return cookies.isEmpty ? nil : cookies
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func readNullTerminatedString(_ data: Data, from offset: Int, maxLength: Int) -> String? {
        guard offset >= 0, offset < data.count, maxLength > 0 else { return nil }
        let end = min(offset + maxLength, data.count)
        var bytes = Data()
        for i in offset..<end {
            let byte = data[i]
            if byte == 0 { break }
            bytes.append(byte)
        }
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
