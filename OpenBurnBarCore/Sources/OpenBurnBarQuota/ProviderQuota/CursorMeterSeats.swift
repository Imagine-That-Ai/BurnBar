import Foundation

// MARK: - Cursor meter seats
//
// A seat is one Cursor product session that can refresh usage-summary.
// This is the AI-provider credential plane, not BurnBar / Firebase login.

public struct CursorMeterInstall: Equatable, Sendable {
    public let label: String
    public let applicationSupportName: String
    public let stateDatabasePath: String

    public init(label: String, applicationSupportName: String, stateDatabasePath: String) {
        self.label = label
        self.applicationSupportName = applicationSupportName
        self.stateDatabasePath = stateDatabasePath
    }
}

public struct CursorMeterSeat: Equatable, Sendable {
    public static let defaultSeatID = "default"
    public static let defaultCookieAccount = "cursor_cookie"
    public static let seatIndexAccount = "cursor_cookie.seats"

    public let seatID: String
    public let installLabel: String
    public let userID: String
    public let email: String?
    public let membershipType: String?
    public let cookieHeader: String
    public let keychainAccount: String
    public let sourcePath: String?

    public init(
        seatID: String,
        installLabel: String,
        userID: String,
        email: String?,
        membershipType: String?,
        cookieHeader: String,
        keychainAccount: String,
        sourcePath: String?
    ) {
        self.seatID = seatID
        self.installLabel = installLabel
        self.userID = userID
        self.email = email
        self.membershipType = membershipType
        self.cookieHeader = cookieHeader
        self.keychainAccount = keychainAccount
        self.sourcePath = sourcePath
    }

    public var displayIdentity: String {
        if let email, !email.isEmpty {
            return "\(installLabel) · \(email)"
        }
        if !userID.isEmpty {
            return "\(installLabel) · \(userID)"
        }
        return installLabel
    }
}

public struct CursorMeterPersistPlan: Equatable, Sendable {
    public struct Write: Equatable, Sendable {
        public let account: String
        public let value: String

        public init(account: String, value: String) {
            self.account = account
            self.value = value
        }
    }

    public let writes: [Write]
    public let seat: CursorMeterSeat
    public let avoidedOverwrite: Bool

    public init(writes: [Write], seat: CursorMeterSeat, avoidedOverwrite: Bool) {
        self.writes = writes
        self.seat = seat
        self.avoidedOverwrite = avoidedOverwrite
    }
}

public enum CursorMeterSeatPlanning {
    public static let knownInstallNames = [
        "Cursor",
        "Cursor Nightly",
        "Cursor-2",
        "Cursor 2"
    ]

    public static func cookieAccount(forSeatID seatID: String) -> String {
        if seatID == CursorMeterSeat.defaultSeatID || seatID.isEmpty {
            return CursorMeterSeat.defaultCookieAccount
        }
        return "\(CursorMeterSeat.defaultCookieAccount).\(seatID)"
    }

    public static func seatID(installLabel: String, userID: String) -> String {
        let install = slug(installLabel)
        let user = slug(userID)
        if install.isEmpty && user.isEmpty {
            return CursorMeterSeat.defaultSeatID
        }
        if install == "cursor" || install.isEmpty {
            return user.isEmpty ? CursorMeterSeat.defaultSeatID : user
        }
        if user.isEmpty {
            return install
        }
        return "\(install)_\(user)"
    }

    public static func workosCookieValue(fromCookieHeader header: String) -> String? {
        let pairs = header.split(separator: ";")
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<separator]
            if name == "WorkosCursorSessionToken" {
                let value = trimmed[trimmed.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        if header.contains("::"), !header.contains("=") {
            return header.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if header.hasPrefix("WorkosCursorSessionToken=") {
            return String(header.dropFirst("WorkosCursorSessionToken=".count))
        }
        return nil
    }

    public static func cookieHeader(fromWorkosValue value: String) -> String {
        if value.hasPrefix("WorkosCursorSessionToken=") {
            return value
        }
        return "WorkosCursorSessionToken=\(value)"
    }

    public static func userID(fromWorkosValue value: String) -> String {
        if let separator = value.range(of: "::") {
            return String(value[..<separator.lowerBound])
        }
        return extractUserID(fromJWT: value)
    }

    public static func accessToken(fromWorkosValue value: String) -> String {
        if let separator = value.range(of: "::") {
            return String(value[separator.upperBound...])
        }
        return value
    }

    public static func extractUserID(fromJWT jwt: String) -> String {
        guard let payload = QuotaJWTPayload.jsonObject(from: jwt),
              let sub = payload["sub"] as? String else {
            return ""
        }
        if let separatorIndex = sub.firstIndex(of: "|") {
            return String(sub[sub.index(after: separatorIndex)...])
        }
        return sub
    }

    public static func isJWTExpired(_ jwt: String, now: Date = Date()) -> Bool {
        guard let payload = QuotaJWTPayload.jsonObject(from: jwt),
              let exp = numericExpiration(payload["exp"]) else {
            return false
        }
        return exp <= now.timeIntervalSince1970
    }

    public static func parseSeatIDs(fromIndexJSON json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted && !$0.isEmpty }
    }

    public static func encodeSeatIDs(_ ids: [String]) -> String {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted && !$0.isEmpty }
        let data = (try? JSONSerialization.data(withJSONObject: unique)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    public static func configuredSeats(fromResolvedKeys keys: [String: String?]) -> [CursorMeterSeat] {
        var seats: [CursorMeterSeat] = []
        var seen = Set<String>()

        func append(account: String, cookie: String, fallbackID: String) {
            let normalized = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  let workos = workosCookieValue(fromCookieHeader: normalized) else {
                return
            }
            let userID = userID(fromWorkosValue: workos)
            let jwt = accessToken(fromWorkosValue: workos)
            if isJWTExpired(jwt) {
                return
            }
            let seatID = fallbackID
            guard seen.insert(seatID).inserted else { return }
            seats.append(
                CursorMeterSeat(
                    seatID: seatID,
                    installLabel: "Cursor",
                    userID: userID,
                    email: nil,
                    membershipType: nil,
                    cookieHeader: cookieHeader(fromWorkosValue: workos),
                    keychainAccount: account,
                    sourcePath: nil
                )
            )
        }

        if let defaultCookie = quotaNonEmpty(keys[CursorMeterSeat.defaultCookieAccount] ?? nil) {
            append(account: CursorMeterSeat.defaultCookieAccount, cookie: defaultCookie, fallbackID: CursorMeterSeat.defaultSeatID)
        }

        for seatID in parseSeatIDs(fromIndexJSON: keys[CursorMeterSeat.seatIndexAccount] ?? nil) {
            let account = cookieAccount(forSeatID: seatID)
            if let cookie = quotaNonEmpty(keys[account] ?? nil) {
                append(account: account, cookie: cookie, fallbackID: seatID)
            }
        }

        for (key, value) in keys {
            guard key.hasPrefix("\(CursorMeterSeat.defaultCookieAccount)."),
                  key != CursorMeterSeat.seatIndexAccount,
                  let cookie = quotaNonEmpty(value ?? nil) else {
                continue
            }
            let seatID = String(key.dropFirst(CursorMeterSeat.defaultCookieAccount.count + 1))
            append(account: key, cookie: cookie, fallbackID: seatID)
        }

        return seats
    }

    public static func loadResolvedKeys(_ read: (String) -> String?) -> [String: String?] {
        var keys: [String: String?] = [:]
        keys[CursorMeterSeat.defaultCookieAccount] = read(CursorMeterSeat.defaultCookieAccount)
        keys[CursorMeterSeat.seatIndexAccount] = read(CursorMeterSeat.seatIndexAccount)
        for seatID in parseSeatIDs(fromIndexJSON: keys[CursorMeterSeat.seatIndexAccount] ?? nil) {
            let account = cookieAccount(forSeatID: seatID)
            keys[account] = read(account)
        }
        return keys
    }

    public static func apply(
        _ plan: CursorMeterPersistPlan,
        writing: (String, String) throws -> Void
    ) rethrows {
        for write in plan.writes {
            try writing(write.account, write.value)
        }
    }

    public static func cookieHeaderIsExpired(_ header: String, now: Date = Date()) -> Bool {
        guard let workos = workosCookieValue(fromCookieHeader: header) else {
            return false
        }
        return isJWTExpired(accessToken(fromWorkosValue: workos), now: now)
    }

    public static func planPersist(
        incomingCookie: String,
        existingDefaultCookie: String?,
        existingSeatIDs: [String],
        installLabel: String,
        email: String? = nil,
        membershipType: String? = nil,
        sourcePath: String? = nil,
        replaceExistingDefault: Bool = false
    ) -> CursorMeterPersistPlan? {
        let trimmed = incomingCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workos = workosCookieValue(fromCookieHeader: trimmed) else {
            return nil
        }
        let jwt = accessToken(fromWorkosValue: workos)
        if isJWTExpired(jwt) {
            return nil
        }
        let userID = userID(fromWorkosValue: workos)
        let incomingHeader = cookieHeader(fromWorkosValue: workos)
        let existingUserID = existingDefaultCookie
            .flatMap(workosCookieValue(fromCookieHeader:))
            .map(userID(fromWorkosValue:))

        let shouldKeepDefault = {
            if replaceExistingDefault {
                return false
            }
            guard let existingUserID, !existingUserID.isEmpty, !userID.isEmpty else {
                return false
            }
            return existingUserID != userID
        }()

        let seatID = shouldKeepDefault
            ? seatID(installLabel: installLabel, userID: userID)
            : CursorMeterSeat.defaultSeatID
        let account = cookieAccount(forSeatID: seatID)
        let seat = CursorMeterSeat(
            seatID: seatID,
            installLabel: installLabel,
            userID: userID,
            email: email,
            membershipType: membershipType,
            cookieHeader: incomingHeader,
            keychainAccount: account,
            sourcePath: sourcePath
        )

        var writes = [CursorMeterPersistPlan.Write(account: account, value: incomingHeader)]
        if shouldKeepDefault {
            var ids = existingSeatIDs
            if !ids.contains(seatID) {
                ids.append(seatID)
            }
            writes.append(
                CursorMeterPersistPlan.Write(
                    account: CursorMeterSeat.seatIndexAccount,
                    value: encodeSeatIDs(ids)
                )
            )
        } else if !existingSeatIDs.isEmpty, !existingSeatIDs.contains(CursorMeterSeat.defaultSeatID) {
            var ids = existingSeatIDs
            if !ids.contains(CursorMeterSeat.defaultSeatID) {
                ids.insert(CursorMeterSeat.defaultSeatID, at: 0)
            }
            writes.append(
                CursorMeterPersistPlan.Write(
                    account: CursorMeterSeat.seatIndexAccount,
                    value: encodeSeatIDs(ids)
                )
            )
        }

        return CursorMeterPersistPlan(writes: writes, seat: seat, avoidedOverwrite: shouldKeepDefault)
    }

    public static func discoverInstalls(
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) -> [CursorMeterInstall] {
        var installs: [CursorMeterInstall] = []
        var seenPaths = Set<String>()

        func append(name: String) {
            let db = applicationSupportURL
                .appendingPathComponent(name)
                .appendingPathComponent("User/globalStorage/state.vscdb")
            guard fileManager.fileExists(atPath: db.path), seenPaths.insert(db.path).inserted else {
                return
            }
            installs.append(
                CursorMeterInstall(
                    label: displayLabel(forApplicationSupportName: name),
                    applicationSupportName: name,
                    stateDatabasePath: db.path
                )
            )
        }

        for name in knownInstallNames {
            append(name: name)
        }

        if let contents = try? fileManager.contentsOfDirectory(
            at: applicationSupportURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                let name = url.lastPathComponent
                guard name.hasPrefix("Cursor") || name.hasPrefix("cursor") else { continue }
                append(name: name)
            }
        }

        return installs
    }

    public static func displayLabel(forApplicationSupportName name: String) -> String {
        switch name {
        case "Cursor": return "Cursor"
        case "Cursor Nightly": return "Cursor Nightly"
        case "Cursor-2", "Cursor 2": return "Cursor-2"
        default: return name
        }
    }

    public static func matchesPinnedIdentity(sessionUserID: String, sessionEmail: String?, seat: CursorMeterSeat) -> Bool {
        if !seat.userID.isEmpty, !sessionUserID.isEmpty {
            return seat.userID == sessionUserID
        }
        if let pinned = seat.email?.lowercased(), !pinned.isEmpty,
           let email = sessionEmail?.lowercased(), !email.isEmpty {
            return pinned == email
        }
        return false
    }

    private static func slug(_ value: String) -> String {
        let lowered = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed
    }

    private static func numericExpiration(_ value: Any?) -> TimeInterval? {
        if let number = value as? Double {
            return number
        }
        if let number = value as? Int {
            return TimeInterval(number)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
}
