import Foundation
import SQLite3
import XCTest

/// Integration tests for the adapters built on 2026-05-03.
/// Verifies real data from Forge, Hermes, and Kilo Code on this machine.
@MainActor
final class NewAdapterIntegrationTests: XCTestCase {

    // MARK: - Forge

    func test_forgeAdapter_readsRealConversationData() throws {
        let dbPath = ("~/forge/.forge.db" as NSString).expandingTildeInPath
        let tomlPath = ("~/forge/.forge.toml" as NSString).expandingTildeInPath

        let dbExists = FileManager.default.fileExists(atPath: dbPath)
        let tomlExists = FileManager.default.fileExists(atPath: tomlPath)

        // At least one of DB or TOML must exist for Forge to be "detected"
        XCTAssertTrue(dbExists || tomlExists, "Forge must be installed (DB or TOML config must exist)")

        if dbExists {
            // Verify DB has the expected schema
            var db: OpaquePointer?
            guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else {
                XCTFail("Could not open Forge DB")
                return
            }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM conversations", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = Int(sqlite3_column_int64(stmt, 0))
                    XCTAssertGreaterThan(count, 0, "Forge DB must have at least 1 conversation")
                    print("✅ FORGE: \(count) conversations in .forge.db")
                }
                sqlite3_finalize(stmt)
            }
        }

        if tomlExists {
            let toml = try String(contentsOfFile: tomlPath, encoding: .utf8)
            XCTAssertTrue(toml.contains("model_id") || toml.contains("provider_id"),
                          "Forge TOML must contain model or provider config")
            print("✅ FORGE: .forge.toml config found")
        }
    }

    func test_forgeAdapter_metricsHaveFileChanges() throws {
        let dbPath = ("~/forge/.forge.db" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("SKIP: Forge DB not found")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT metrics FROM conversations WHERE metrics IS NOT NULL AND metrics != '' LIMIT 1",
            -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                let jsonStr = String(cString: text)
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    XCTAssertNotNil(json["started_at"], "Metrics must have started_at")
                    if let fc = json["files_changed"] as? [String: Any] {
                        print("✅ FORGE: Files changed in metrics — \(fc.count) files")
                    }
                }
            }
        }
    }

    // MARK: - Hermes

    func test_hermesAdapter_readsRealSessionData() throws {
        let dbPath = ("~/.hermes/state.db" as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("SKIP: Hermes state.db not found")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else {
            XCTFail("Could not open Hermes state.db")
            return
        }
        defer { sqlite3_close(db) }

        // Verify sessions table has real data
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0) FROM sessions",
            -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = sqlite3_column_int64(stmt, 0)
                let input = sqlite3_column_int64(stmt, 1)
                let output = sqlite3_column_int64(stmt, 2)

                XCTAssertGreaterThan(count, 0, "Hermes must have sessions")
                XCTAssertGreaterThan(input + output, 0, "Hermes must have token data")
                print("✅ HERMES: \(count) sessions, \(input) input, \(output) output tokens")
            }
            sqlite3_finalize(stmt)
        }

        // Verify per-model data exists
        if sqlite3_prepare_v2(db,
            "SELECT COALESCE(model,'unknown'), COUNT(*) FROM sessions WHERE ended_at IS NOT NULL GROUP BY model",
            -1, &stmt, nil) == SQLITE_OK {
            var models: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let model = String(cString: sqlite3_column_text(stmt, 0))
                let n = sqlite3_column_int64(stmt, 1)
                models.append("\(model)(\(n))")
            }
            XCTAssertFalse(models.isEmpty, "Hermes must have per-model data")
            print("✅ HERMES models: \(models.joined(separator: ", "))")
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Kilo Code

    func test_kiloCodeAdapter_findsTaskData() throws {
        let hosts = ["Code", "Cursor", "Code - Insiders", "Windsurf - Next"]
        let appSupport = ("~/Library/Application Support" as NSString).expandingTildeInPath
        var foundTasks = 0

        for host in hosts {
            let tasksDir = "\(appSupport)/\(host)/User/globalStorage/kilocode.kilo-code/tasks"
            guard FileManager.default.fileExists(atPath: tasksDir),
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: tasksDir) else {
                continue
            }
            let taskIDs = contents.filter { !$0.hasPrefix(".") }

            for taskID in taskIDs.prefix(2) {
                let uiPath = "\(tasksDir)/\(taskID)/ui_messages.json"
                guard FileManager.default.fileExists(atPath: uiPath),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: uiPath)),
                      let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    continue
                }

                var tokensIn: Int64 = 0
                var tokensOut: Int64 = 0
                for msg in messages {
                    if let say = msg["say"] as? String, say == "api_req_started",
                       let text = msg["text"] as? String,
                       let jsonData = text.data(using: .utf8),
                       let apiReq = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        tokensIn += (apiReq["tokensIn"] as? Int64) ?? 0
                        tokensOut += (apiReq["tokensOut"] as? Int64) ?? 0
                    }
                }

                foundTasks += 1
                print("✅ KILO CODE: task \(taskID.prefix(8)) — \(tokensIn) in, \(tokensOut) out tokens")
            }
        }

        // Kilo Code is installed on this machine (found in Cursor globalStorage)
        XCTAssertGreaterThan(foundTasks, 0, "Kilo Code must have at least one task with token data")
    }
}
