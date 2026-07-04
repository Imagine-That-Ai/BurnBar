import Foundation

// MARK: - Cursor Session Token Extractor

/// Extracts Cursor session tokens from Cursor's own SQLite database.
enum CursorCookieExtractor {

    struct CursorSession: Sendable {
        let accessToken: String
        let userId: String
        let email: String?
        let membershipType: String?

        var workosCookieValue: String {
            "\(userId)::\(accessToken)"
        }

        var cookieHeader: String {
            "WorkosCursorSessionToken=\(workosCookieValue)"
        }
    }

    private static let cursorDBPath = (
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb" as NSString
    ).expandingTildeInPath

    private static let alternateDBPaths: [String] = [
        cursorDBPath,
        (
            "~/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb"
            as NSString
        ).expandingTildeInPath
    ]

    static func readSession() -> CursorSession? {
        for dbPath in alternateDBPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }

            guard let accessToken = readValue(at: dbPath, key: "cursorAuth/accessToken"),
                  !accessToken.isEmpty else {
                continue
            }

            let userId = extractUserIdFromJWT(accessToken)
            let email = readValue(at: dbPath, key: "cursorAuth/cachedEmail")
            let membershipType = readValue(at: dbPath, key: "cursorAuth/stripeMembershipType")

            return CursorSession(
                accessToken: accessToken,
                userId: userId,
                email: email,
                membershipType: membershipType
            )
        }
        return nil
    }

    static func extractCookieHeader() -> String? {
        readSession()?.cookieHeader
    }

    private static func readValue(at path: String, key: String) -> String? {
        do {
            let reader = try SQLiteConnection.openReadOnly(path: path)
            defer { reader.close() }
            let rows = try reader.query(
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                arguments: [.text(key)]
            )
            return rows.first?.string("value")
        } catch {
            return nil
        }
    }

    private static func extractUserIdFromJWT(_ jwt: String) -> String {
        guard let payload = QuotaJWTPayload.jsonObject(from: jwt),
              let sub = payload["sub"] as? String else {
            return ""
        }
        if let separatorIndex = sub.firstIndex(of: "|") {
            return String(sub[sub.index(after: separatorIndex)...])
        }
        return sub
    }
}