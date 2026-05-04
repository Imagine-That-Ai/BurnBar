import Foundation
import XCTest
import SQLite3

/// Live integration test: extracts JWT from Cursor's SQLite DB,
/// hits cursor.sh/api/usage-summary, asserts real numbers.
/// Only runs when Cursor is installed and signed in.
@MainActor
final class CursorIntegrationTests: XCTestCase {

    func test_liveCursorAPI_returnsExactUsage() throws {
        let dbPath = ("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("SKIP: Cursor DB not found")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { print("SKIP: cannot open DB"); return }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK else {
            print("SKIP: cannot query DB"); return
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let jwtPtr = sqlite3_column_text(stmt, 0) else { print("SKIP: no token"); return }
        let jwt = String(cString: jwtPtr)
        guard jwt.hasPrefix("eyJ") else { print("SKIP: not a JWT"); return }

        // Decode userId
        let parts = jwt.components(separatedBy: ".")
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let payloadData = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let userId = payload["sub"] as? String else { print("SKIP: cannot decode JWT"); return }

        // Hit the live API
        let cookieHeader = "WorkosCursorSessionToken=\(userId)::\(jwt)"
        var request = URLRequest(url: URL(string: "https://cursor.sh/api/usage-summary")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 15

        let exp = XCTestExpectation(description: "api")
        var statusCode = 0
        var json: [String: Any]?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { exp.fulfill() }
            guard let http = response as? HTTPURLResponse else { return }
            statusCode = http.statusCode
            guard let data else { return }
            json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.resume()
        wait(for: [exp], timeout: 20)

        XCTAssertEqual(statusCode, 200, "Cursor API must return HTTP 200")
        let j = try XCTUnwrap(json, "Must have valid JSON response")

        // Verify key fields from the real API
        let membershipType = j["membershipType"] as? String
        XCTAssertNotNil(membershipType)
        XCTAssertFalse(membershipType?.isEmpty ?? true)

        let plan = ((j["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])
        let usedCents = plan?["used"] as? Int ?? 0
        let limitCents = plan?["limit"] as? Int ?? 0
        XCTAssertGreaterThan(limitCents, 0, "Plan limit must be > 0")
        XCTAssertGreaterThanOrEqual(usedCents, 0)
        XCTAssertLessThanOrEqual(usedCents, limitCents)

        let totalPct = plan?["totalPercentUsed"] as? Double ?? 0
        XCTAssertGreaterThanOrEqual(totalPct, 0)
        XCTAssertLessThanOrEqual(totalPct, 100)

        let autoPct = plan?["autoPercentUsed"] as? Double ?? 0
        let apiPct = plan?["apiPercentUsed"] as? Double ?? 0
        XCTAssertGreaterThanOrEqual(autoPct, 0)
        XCTAssertGreaterThanOrEqual(apiPct, 0)

        print("✅ CURSOR LIVE: \(membershipType!), $\(String(format: "%.2f", Double(usedCents)/100))/\(String(format: "%.2f", Double(limitCents)/100)) (\(String(format: "%.1f", totalPct))%)")
    }
}
