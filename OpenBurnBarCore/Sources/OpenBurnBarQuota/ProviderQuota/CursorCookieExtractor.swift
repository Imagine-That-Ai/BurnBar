import Foundation
import OpenBurnBarSQLiteReader

// MARK: - Cursor Session Token Extractor

/// Extracts Cursor session tokens from Cursor's own SQLite database.
public enum CursorCookieExtractor {

    public struct CursorSession: Sendable, Equatable {
        public let accessToken: String
        public let userId: String
        public let email: String?
        public let membershipType: String?

        public var workosCookieValue: String {
            "\(userId)::\(accessToken)"
        }

        public var cookieHeader: String {
            "WorkosCursorSessionToken=\(workosCookieValue)"
        }

        public init(accessToken: String, userId: String, email: String?, membershipType: String?) {
            self.accessToken = accessToken
            self.userId = userId
            self.email = email
            self.membershipType = membershipType
        }
    }

    public struct DiscoveredSession: Sendable, Equatable {
        public let install: CursorMeterInstall
        public let session: CursorSession

        public init(install: CursorMeterInstall, session: CursorSession) {
            self.install = install
            self.session = session
        }
    }

    public static func defaultApplicationSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// First non-expired session among discovered installs. Unconfigured default
    /// seats still use this convenience path; pinned seats must match identity.
    public static func readSession() -> CursorSession? {
        readAllSessions().first?.session
    }

    public static func extractCookieHeader() -> String? {
        readSession()?.cookieHeader
    }

    public static func readAllSessions(
        applicationSupportURL: URL = CursorCookieExtractor.defaultApplicationSupportURL(),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [DiscoveredSession] {
        discoverSessions(
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager,
            now: now
        )
    }

    public static func discoverSessions(
        applicationSupportURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [DiscoveredSession] {
        CursorMeterSeatPlanning.discoverInstalls(
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        ).compactMap { install in
            guard let session = readSession(
                at: install.stateDatabasePath,
                now: now
            ) else {
                return nil
            }
            return DiscoveredSession(install: install, session: session)
        }
    }

    public static func readSession(at dbPath: String, now: Date = Date()) -> CursorSession? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        guard let accessToken = readValue(at: dbPath, key: "cursorAuth/accessToken"),
              !accessToken.isEmpty else {
            return nil
        }
        if CursorMeterSeatPlanning.isJWTExpired(accessToken, now: now) {
            return nil
        }

        let userId = CursorMeterSeatPlanning.extractUserID(fromJWT: accessToken)
        let email = readValue(at: dbPath, key: "cursorAuth/cachedEmail")
        let membershipType = readValue(at: dbPath, key: "cursorAuth/stripeMembershipType")

        return CursorSession(
            accessToken: accessToken,
            userId: userId,
            email: email,
            membershipType: membershipType
        )
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
}
