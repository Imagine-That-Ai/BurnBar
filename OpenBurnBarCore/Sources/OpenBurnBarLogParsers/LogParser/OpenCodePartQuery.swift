import Foundation

/// SQL for OpenCode `part` reads. Named message-id columns stay the fast
/// path. JSON-only schemas cannot invent that column; `json_extract` on an
/// existing payload column bounds the same ids instead of `SELECT … FROM part`.
public enum OpenCodePartQuery: Sendable {
    public static let chunkSize = 400
    public static let idColumns = ["messageID", "message_id", "messageId"]
    public static let payloadColumns = ["data", "json", "value", "content", "payload"]
    public static let jsonMessageIDPaths = ["$.messageID", "$.message_id", "$.messageId"]

    public static let jsonExtractProbeSQL = #"SELECT json_extract('{"a":"ok"}', '$.a') AS probe"#

    public static func selectList(
        existingColumns: Set<String>,
        required: [String] = []
    ) -> String {
        var selected: [String] = []
        var seen = Set<String>()
        for column in required + idColumns + payloadColumns {
            guard existingColumns.contains(column), seen.insert(column).inserted else { continue }
            selected.append(column)
        }
        return selected.isEmpty ? "*" : selected.joined(separator: ", ")
    }

    public static func idColumn(in columns: Set<String>) -> String? {
        idColumns.first { columns.contains($0) }
    }

    public static func payloadColumn(in columns: Set<String>) -> String? {
        payloadColumns.first { columns.contains($0) }
    }

    public static func jsonExtractProbeSucceeded(intValue: Int64? = nil, textValue: String? = nil) -> Bool {
        if textValue == "ok" { return true }
        if intValue == 1 { return true }
        return false
    }

    /// `COALESCE(json_extract(payload, '$.messageID'), …) IN (?,?,…)`.
    /// Returns `nil` when `payloadColumn` is not in the allowlist.
    public static func jsonExtractWhereSQL(payloadColumn: String, placeholderCount: Int) -> String? {
        guard payloadColumns.contains(payloadColumn), placeholderCount > 0 else { return nil }
        let placeholders = Array(repeating: "?", count: placeholderCount).joined(separator: ",")
        let extracts = jsonMessageIDPaths
            .map { "json_extract(\(payloadColumn), '\($0)')" }
            .joined(separator: ", ")
        return "COALESCE(\(extracts)) IN (\(placeholders))"
    }

    public static func idColumnWhereSQL(idColumn: String, placeholderCount: Int) -> String? {
        guard idColumns.contains(idColumn), placeholderCount > 0 else { return nil }
        let placeholders = Array(repeating: "?", count: placeholderCount).joined(separator: ",")
        return "\(idColumn) IN (\(placeholders))"
    }
}
