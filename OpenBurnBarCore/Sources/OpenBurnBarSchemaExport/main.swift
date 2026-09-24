import CryptoKit
import Foundation
import GRDB
import OpenBurnBarData

// OpenBurnBarSchemaExport — Wave 2.3 schema-doc generator.
//
// Runs the live OpenBurnBarData migrator on an in-memory database and emits
// docs/SCHEMA_SQLITE.sql from the resulting sqlite_master DDL. The doc is
// byte-truth from the migrator, not a hand copy: every statement in the file
// is the verbatim `sql` column sqlite recorded when the migration ran.
//
// Usage:
//   swift run --package-path OpenBurnBarCore OpenBurnBarSchemaExport [--check]
//     [--repo-root <path>] [--output <path>]
//   --check      Regenerate in memory and fail (exit 1) if the committed doc
//                differs by even one byte. Also fails if the schema hash
//                disagrees with the DB byte-compat vector.
//   --repo-root  Repo root. Default: discovered from the working directory
//                (the directory containing OpenBurnBarCore/Package.swift,
//                or its parent when run from inside OpenBurnBarCore).
//   --output     Output path. Default: <repo-root>/docs/SCHEMA_SQLITE.sql.
//
// Never-referenced-leaf executable: no product, absent from project.yml.

private struct ExportOptions {
    var check = false
    var repoRootOverride: String?
    var outputOverride: String?
}

private func parseArguments(_ arguments: [String]) throws -> ExportOptions {
    var options = ExportOptions()
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--check":
            options.check = true
        case "--repo-root":
            index += 1
            guard index < arguments.count else { throw ExportError.usage("--repo-root needs a value") }
            options.repoRootOverride = arguments[index]
        case "--output":
            index += 1
            guard index < arguments.count else { throw ExportError.usage("--output needs a value") }
            options.outputOverride = arguments[index]
        case "--help", "-h":
            throw ExportError.usage(nil)
        default:
            throw ExportError.usage("unknown argument: \(argument)")
        }
        index += 1
    }
    return options
}

private enum ExportError: Error, CustomStringConvertible {
    case usage(String?)
    case failure(String)

    var description: String {
        switch self {
        case .usage(let detail):
            let help = """
            usage: OpenBurnBarSchemaExport [--check] [--repo-root <path>] [--output <path>]
              Regenerate docs/SCHEMA_SQLITE.sql from the live OpenBurnBarData migrator.
              --check compares against the committed file instead of writing it.
            """
            if let detail {
                return "error: \(detail)\n\(help)"
            }
            return help
        case .failure(let detail):
            return "error: \(detail)"
        }
    }
}

private struct SchemaEntry: Equatable {
    var type: String
    var name: String
    var sql: String
}

private func discoverRepoRoot(override: String?) throws -> URL {
    if let override {
        return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let packageHere = current.appendingPathComponent("OpenBurnBarCore/Package.swift")
    if FileManager.default.fileExists(atPath: packageHere.path) {
        return current.standardizedFileURL
    }
    let packageBelow = current.appendingPathComponent("Package.swift")
    if FileManager.default.fileExists(atPath: packageBelow.path) {
        return current.deletingLastPathComponent().standardizedFileURL
    }
    throw ExportError.failure(
        "cannot find the repo root from \(current.path): pass --repo-root"
    )
}

/// The sqlite_master rows for a migrated queue: verbatim DDL, sqlite-internal
/// objects excluded, ordered by (type, name) — the same canonicalization the
/// DB byte-compat vector hashes.
private func schemaEntries(_ queue: DatabaseQueue) throws -> [SchemaEntry] {
    try queue.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT type, name, sql FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """)
        return rows.map { row in
            SchemaEntry(
                type: row["type"],
                name: row["name"],
                sql: (row["sql"] as String).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private func schemaHashHex(_ entries: [SchemaEntry]) -> String {
    let canonical = entries.map(\.sql).joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Trace every endpoint object back to the migration that introduced it by
/// migrating a fresh in-memory database up to each identifier in turn and
/// diffing the object-name sets. Fail-closed: an untraceable endpoint object
/// is an export bug, not a doc wart.
private func provenanceByObject(
    identifiers: [String],
    endpointNames: Set<String>
) throws -> [String: String] {
    var provenance: [String: String] = [:]
    var seen: Set<String> = []
    for identifier in identifiers {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: identifier)
        let names = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        }
        for name in names where seen.contains(name) == false {
            seen.insert(name)
            provenance[name] = identifier
        }
    }
    let untraced = endpointNames.subtracting(provenance.keys)
    if untraced.isEmpty == false {
        throw ExportError.failure(
            "cannot trace endpoint objects to a migration: \(untraced.sorted().joined(separator: ", "))"
        )
    }
    return provenance
}

private func renderDocument(
    entries: [SchemaEntry],
    identifiers: [String],
    provenance: [String: String],
    hashHex: String
) -> String {
    var lines: [String] = []
    lines.append("-- GENERATED BY `swift run --package-path OpenBurnBarCore OpenBurnBarSchemaExport`.")
    lines.append("-- DO NOT EDIT: this file is byte-truth from the live OpenBurnBarData migrator.")
    lines.append("-- Regenerate after any migration change; CI fails on any drift.")
    lines.append("--")
    lines.append("-- Source of truth: OpenBurnBarDatabase.migrator (OpenBurnBarCore/Sources/OpenBurnBarData).")
    lines.append("-- Database file (production): ~/Library/Application Support/OpenBurnBar/openburnbar.sqlite")
    lines.append("-- migrationEndpoint: \(identifiers.last ?? "")")
    lines.append("-- migrationCount: \(identifiers.count)")
    lines.append("-- schemaHashSHA256: \(hashHex) (sha256 over trimmed sqlite_master DDL ordered by type,name;")
    lines.append("--   same algorithm as the DB byte-compat vector — the two MUST agree).")
    lines.append("--")
    lines.append("-- Statements are the verbatim `sql` sqlite recorded, ordered by (type, name).")
    lines.append("-- FTS5 shadow tables (<fts>_data/_idx/_content/_docsize/_config) are real file")
    lines.append("-- objects and are included. `sqlite_%` internals are excluded.")
    lines.append("")
    for entry in entries {
        let introduced = provenance[entry.name] ?? "unknown"
        lines.append("-- ── \(entry.type) \(entry.name) ── (introduced: \(introduced))")
        lines.append(entry.sql + ";")
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// Typed projection of the DB byte-compat vector: only the schema hash is
/// read. (Decodable instead of `[String: Any]` casts per the string-any ratchet.)
private struct ByteCompatVectorFile: Decodable {
    var schemaHashSHA256: String?
}

private func byteCompatVectorHash(repoRoot: URL) throws -> String? {
    let url = repoRoot
        .appendingPathComponent("AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-vector.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let vector: ByteCompatVectorFile
    do {
        vector = try JSONDecoder().decode(ByteCompatVectorFile.self, from: data)
    } catch {
        throw ExportError.failure("byte-compat vector is not a JSON object: \(url.path)")
    }
    return vector.schemaHashSHA256
}

private func run() throws -> Int32 {
    let options = try parseArguments(CommandLine.arguments)
    let repoRoot = try discoverRepoRoot(override: options.repoRootOverride)
    let outputURL: URL
    if let outputOverride = options.outputOverride {
        outputURL = URL(fileURLWithPath: outputOverride)
    } else {
        outputURL = repoRoot.appendingPathComponent("docs/SCHEMA_SQLITE.sql")
    }

    let identifiers = OpenBurnBarDatabase.migrator.migrations
    guard identifiers.isEmpty == false else {
        throw ExportError.failure("migrator registered zero migrations")
    }
    let endpointQueue = try DatabaseQueue()
    try OpenBurnBarDatabase(databaseQueue: endpointQueue).runMigrations()
    let entries = try schemaEntries(endpointQueue)
    guard entries.isEmpty == false else {
        throw ExportError.failure("migrated database has no sqlite_master entries")
    }
    let provenance = try provenanceByObject(
        identifiers: identifiers,
        endpointNames: Set(entries.map(\.name))
    )
    let hashHex = schemaHashHex(entries)
    let document = renderDocument(
        entries: entries,
        identifiers: identifiers,
        provenance: provenance,
        hashHex: hashHex
    )

    if let vectorHash = try byteCompatVectorHash(repoRoot: repoRoot), vectorHash != hashHex {
        throw ExportError.failure(
            "schema hash \(hashHex) disagrees with the DB byte-compat vector (\(vectorHash)): " +
            "regenerate the vector (DatabaseByteCompatVectorTests) alongside this doc"
        )
    } else if options.check {
        let committed = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        if committed != document {
            throw ExportError.failure(
                "docs/SCHEMA_SQLITE.sql drifted from the migrator: run " +
                "`swift run --package-path OpenBurnBarCore OpenBurnBarSchemaExport` and commit the result"
            )
        }
        print("schema doc matches the migrator (\(entries.count) objects, \(identifiers.count) migrations, hash \(hashHex))")
        return 0
    }

    try document.write(to: outputURL, atomically: true, encoding: .utf8)
    print("wrote \(outputURL.path) (\(entries.count) objects, \(identifiers.count) migrations, hash \(hashHex))")
    return 0
}

do {
    exit(try run())
} catch let error as ExportError {
    FileHandle.standardError.write(Data((error.description + "\n").utf8))
    switch error {
    case .usage: exit(2)
    case .failure: exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
