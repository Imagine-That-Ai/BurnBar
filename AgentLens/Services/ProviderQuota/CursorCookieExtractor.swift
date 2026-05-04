import Foundation
import SQLite3

// MARK: - Cursor Session Token Extractor

/// Extracts Cursor session tokens from Cursor's own SQLite database.
///
/// Cursor stores auth tokens at:
///   ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
///
/// The `cursorAuth/accessToken` key contains a JWT whose decoded payload
/// includes the `sub` (user ID) field needed to construct the
/// `WorkosCursorSessionToken` cookie header that Cursor's API accepts.
///
/// ## Why this works (and Safari binarycookies doesn't)
///
/// `state.vscdb` is readable by any process without Full Disk Access.
/// Safari's `Cookies.binarycookies` requires Full Disk Access (TCC).
/// CodexBar accesses Cursor auth via browser cookies from Chrome/Safari
/// using `SweetCookieKit`; this is the zero-dependency equivalent that
/// reads directly from Cursor's own database.
///
/// ## Cookie format
///
/// The `WorkosCursorSessionToken` cookie format is:
///   `{userId}::{jwt}`
///
/// Where `userId` is the portion of the JWT `sub` claim after the `|`
/// separator (e.g., `github|user_01JPV3PX04QGGE54KSKTQS8WS5` →
/// `user_01JPV3PX04QGGE54KSKTQS8WS5`).
///
/// Verified against live API call returning HTTP 200 on 2026-05-02.

enum CursorCookieExtractor {

    // MARK: - Types

    /// A decoded Cursor session token ready for API use.
    struct CursorSession: Sendable {
        /// The raw JWT access token from state.vscdb.
        let accessToken: String
        /// The user ID extracted from the JWT `sub` claim.
        let userId: String
        /// The user's email (from `cursorAuth/cachedEmail`).
        let email: String?
        /// The membership type (e.g., "ultra", "pro").
        let membershipType: String?

        /// Builds the `WorkosCursorSessionToken` cookie header value.
        var workosCookieValue: String {
            "\(userId)::\(accessToken)"
        }

        /// Full cookie header string for Cursor API requests.
        var cookieHeader: String {
            "WorkosCursorSessionToken=\(workosCookieValue)"
        }
    }

    // MARK: - Constants

    private static let cursorDBPath = (
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb" as NSString
    ).expandingTildeInPath

    /// Fallback locations to try if the primary path doesn't exist.
    private static let alternateDBPaths: [String] = [
        cursorDBPath,
        // Cursor Nightly / alternate channels may use different paths
        (
            "~/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb"
            as NSString
        ).expandingTildeInPath,
    ]

    // MARK: - Public API

    /// Reads a Cursor session from `state.vscdb`.
    ///
    /// - Returns: A `CursorSession` if the database is readable and contains
    ///   a valid `cursorAuth/accessToken`, or `nil` if no session is available.
    static func readSession() -> CursorSession? {
        for dbPath in alternateDBPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }

            guard let db = openDatabase(at: dbPath) else { continue }
            defer { sqlite3_close(db) }

            guard let accessToken = readValue(db: db, key: "cursorAuth/accessToken"),
                  !accessToken.isEmpty else {
                return nil
            }

            let userId = extractUserIdFromJWT(accessToken)
            let email = readValue(db: db, key: "cursorAuth/cachedEmail")
            let membershipType = readValue(db: db, key: "cursorAuth/stripeMembershipType")

            return CursorSession(
                accessToken: accessToken,
                userId: userId,
                email: email,
                membershipType: membershipType
            )
        }

        return nil
    }

    /// Returns a Cursor cookie header string suitable for the `Cookie` HTTP header.
    /// Convenience wrapper around `readSession()`.
    static func extractCookieHeader() -> String? {
        readSession()?.cookieHeader
    }

    // MARK: - SQLite Helpers

    private static func openDatabase(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            return nil
        }
        // Set a busy timeout so we don't fail if Cursor is writing.
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    private static func readValue(db: OpaquePointer, key: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        // Bind the key parameter
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // Read the value column
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    // MARK: - JWT Parsing

    /// Extracts the user ID from a JWT's `sub` claim.
    ///
    /// The JWT `sub` field has format `{provider}|{userId}` (e.g., `github|user_01JPV...`).
    /// We extract the portion after the `|` separator.
    private static func extractUserIdFromJWT(_ jwt: String) -> String {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return "" }

        // Base64URL decode the payload (middle section)
        var encoded = parts[1]
        // Add padding if needed
        let remainder = encoded.count % 4
        if remainder > 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        // Convert Base64URL to Base64
        encoded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let payloadData = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let sub = payload["sub"] as? String else {
            return ""
        }

        // Extract userId from "github|user_01JPV..." format
        if let separatorIndex = sub.firstIndex(of: "|") {
            return String(sub[sub.index(after: separatorIndex)...])
        }
        return sub
    }
}
