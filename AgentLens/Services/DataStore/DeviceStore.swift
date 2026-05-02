import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - DeviceStore

/// Device CRUD and per-device usage summaries.
final class DeviceStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchDevices() throws -> [DeviceRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM devices ORDER BY isLocal DESC, deviceName ASC")
            return rows.compactMap { row -> DeviceRecord? in
                guard let deviceId = row["deviceId"] as? String,
                      let deviceName = row["deviceName"] as? String else { return nil }
                return DeviceRecord(
                    deviceId: deviceId, deviceName: deviceName,
                    isLocal: ((row["isLocal"] as? Int) ?? 0) != 0,
                    lastSeenAt: OpenBurnBarDatabase.parseDateValue(row["lastSeenAt"]),
                    createdAt: OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date(),
                    hardwareModel: row["hardwareModel"] as? String,
                    customIcon: row["customIcon"] as? String
                )
            }
        }
    }

    func upsertDevice(_ device: DeviceRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO devices (deviceId, deviceName, isLocal, lastSeenAt, createdAt, hardwareModel, customIcon)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId) DO UPDATE SET
                        deviceName = excluded.deviceName,
                        lastSeenAt = excluded.lastSeenAt,
                        hardwareModel = COALESCE(excluded.hardwareModel, devices.hardwareModel),
                        customIcon = COALESCE(excluded.customIcon, devices.customIcon)
                    """,
                arguments: [device.deviceId, device.deviceName, device.isLocal ? 1 : 0, device.lastSeenAt, device.createdAt, device.hardwareModel, device.customIcon]
            )
        }
    }

    func deviceUsageSummaries() throws -> [DeviceUsageSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(tu.sourceDeviceId, d_local.deviceId) AS deviceId,
                    COALESCE(tu.sourceDeviceName, d_local.deviceName, 'This Mac') AS deviceName,
                    CASE WHEN tu.sourceDeviceId IS NULL THEN 1 ELSE 0 END AS isLocal,
                    SUM(tu.cost) AS totalCost,
                    SUM(tu.totalTokens) AS totalTokens,
                    COUNT(DISTINCT tu.sessionId) AS sessionCount,
                    d.hardwareModel AS hardwareModel,
                    d.customIcon AS customIcon
                FROM token_usage tu
                LEFT JOIN devices d_local ON d_local.isLocal = 1
                LEFT JOIN devices d ON d.deviceId = COALESCE(tu.sourceDeviceId, d_local.deviceId)
                GROUP BY COALESCE(tu.sourceDeviceId, 'local')
                ORDER BY isLocal DESC, totalCost DESC
                """)
            return rows.compactMap { row -> DeviceUsageSummary? in
                DeviceUsageSummary(
                    deviceId: row["deviceId"] as? String,
                    deviceName: (row["deviceName"] as? String) ?? "Unknown",
                    isLocal: ((row["isLocal"] as? Int) ?? 0) != 0,
                    totalCost: (row["totalCost"] as? Double) ?? 0,
                    totalTokens: (row["totalTokens"] as? Int) ?? Int(row["totalTokens"] as? Int64 ?? 0),
                    sessionCount: (row["sessionCount"] as? Int) ?? Int(row["sessionCount"] as? Int64 ?? 0),
                    hardwareModel: row["hardwareModel"] as? String,
                    customIcon: row["customIcon"] as? String
                )
            }
        }
    }

    func updateDeviceIcon(deviceId: String, customIcon: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devices SET customIcon = ? WHERE deviceId = ?",
                arguments: [customIcon, deviceId]
            )
        }
    }
}
