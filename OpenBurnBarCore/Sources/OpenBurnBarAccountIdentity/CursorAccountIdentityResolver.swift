import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

/// Resolves the Cursor seat currently signed in to the Cursor editor from
/// Cursor's own `state.vscdb` (`cursorAuth/cachedEmail`).
///
/// Only the cached email is read — the resolver deliberately never touches
/// `cursorAuth/accessToken` or any other credential row, matching the quota
/// layer's security posture for usage attribution.
public struct CursorAccountIdentityResolver: ProviderAccountIdentityResolving {
    public let providers: [AgentProvider] = [.cursor]

    private let databaseCandidates: [String]
    private let fileManager: FileManager

    public init(
        databaseCandidates: [String]? = nil,
        fileManager: FileManager = .default
    ) {
        self.databaseCandidates = databaseCandidates ?? [
            ("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb" as NSString)
                .expandingTildeInPath,
            ("~/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb" as NSString)
                .expandingTildeInPath
        ]
        self.fileManager = fileManager
    }

    public func resolveCurrentIdentity() -> ResolvedProviderAccountIdentity? {
        for path in databaseCandidates {
            guard fileManager.fileExists(atPath: path) else { continue }
            guard let email = readItemTableValue(at: path, key: "cursorAuth/cachedEmail")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !email.isEmpty else { continue }
            return ResolvedProviderAccountIdentity(
                rawIdentity: email.lowercased(),
                label: email,
                scope: .localOnly
            )
        }
        return nil
    }

    private func readItemTableValue(at path: String, key: String) -> String? {
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
