import Foundation
import OpenBurnBarKernel

// MARK: - Cursor connector credentials (replaces per-adapter KeychainStore reads)

public extension ProviderQuotaAdapterContext {
    /// Reads a Cursor-connector API key stored under the canonical connector service.
    func cursorConnectorCredential(for account: String) -> String? {
        quotaNonEmpty(
            secretStore.string(
                for: account,
                service: OpenBurnBarIdentity.cursorConnectorKeychainService
            )
        )
    }

    /// Best-effort diagnostic routed through `quotaLogger` (Engine-safe; no AppLogger).
    func quotaLogSilentFailure(_ message: String) {
        quotaLogger.log(message)
    }
}

// MARK: - JWT payload parse (Kimi / Cursor / Claude OAuth cache paths)

public enum QuotaJWTPayload {
    /// Decodes the middle segment of a JWT into a JSON object (no signature verify).
    public static func jsonObject(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public enum QuotaSHA256 {
    public static func hexDigest(_ utf8: String) -> String {
        hexDigest(Data(utf8.utf8))
    }

    public static func hexDigest(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public extension SecretStore {
    /// Optional write path for macOS keychain bridges; no-op by default (Windows).
    func setString(_ value: String, for account: String, service: String) throws {}
}
