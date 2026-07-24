import Foundation
import OpenBurnBarEngine

extension BurnBarProjectCodeMemoryStore {
    func insertSymbol(_ symbol: ExtractedSymbol, indexedAt: String) throws {
        let rangeJSON = try encodeJSONString(symbol.range)
        try execute(
            """
            INSERT OR IGNORE INTO code_symbols
                (id, project_id, artifact_id, blob_sha, name, kind, range_json, confidence_tier, tier_evidence_json, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(symbol.id), .text(symbol.projectID), .text(symbol.artifactID), .text(symbol.blobSHA),
                .text(symbol.name), .text(symbol.kind), .text(rangeJSON), .text(symbol.confidenceTier),
                symbol.tierEvidenceJSON.map(SQLiteBind.text) ?? .null, .text(indexedAt)
            ]
        )
    }

    func buildReferences(projectID: String, root: URL, artifacts: [IndexedArtifact], indexedAt: String) throws {
        let symbols = try querySymbols(
            """
            SELECT s.id, s.artifact_id, a.file_path, s.name, s.kind, s.range_json,
                   s.confidence_tier, s.blob_sha, s.tier_evidence_json
            FROM code_symbols s
            JOIN code_artifacts a ON a.id = s.artifact_id
            WHERE s.project_id = ?
            """,
            [.text(projectID)]
        )
        guard symbols.isEmpty == false else { return }
        let symbolsByArtifact = Dictionary(grouping: symbols, by: \.artifactID)
        let symbolsByName = Dictionary(grouping: symbols, by: \.name)
        for artifact in artifacts {
            let fileURL = root.appendingPathComponent(artifact.filePath, isDirectory: false)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fileSymbols = (symbolsByArtifact[artifact.id] ?? []).sorted { $0.range.startLine < $1.range.startLine }
            let lines = text.components(separatedBy: .newlines)
            for (lineIndex, line) in lines.enumerated() {
                let scanLine = Self.referenceScanLine(line)
                let caller = fileSymbols.last(where: { $0.range.startLine <= lineIndex + 1 })
                for token in Self.identifierTokens(in: scanLine) {
                    guard let targets = symbolsByName[token] else { continue }
                    for target in targets {
                        if target.artifactID == artifact.id, target.range.startLine == lineIndex + 1 { continue }
                        let refID = "ref_" + String(Self.sha256Hex("\(projectID):\(artifact.id):\(target.id):\(lineIndex + 1)").prefix(32))
                        let range = BurnBarProjectCodeRange(startLine: lineIndex + 1, endLine: lineIndex + 1)
                        try execute(
                            """
                            INSERT OR IGNORE INTO code_references
                                (id, project_id, from_artifact_id, to_symbol_id, range_json, blob_sha, confidence_tier, indexed_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            [
                                .text(refID), .text(projectID), .text(artifact.id), .text(target.id),
                                .text(try encodeJSONString(range)), .text(artifact.blobSHA), .text("lexical_fallback"), .text(indexedAt)
                            ]
                        )
                        if let caller, Self.lineContainsCall(to: target.name, in: scanLine), caller.id != target.id {
                            let edgeID = "edge_" + String(Self.sha256Hex("\(projectID):\(caller.id):\(target.id)").prefix(32))
                            try execute(
                                """
                                INSERT OR IGNORE INTO code_call_edges
                                    (id, project_id, caller_symbol_id, callee_symbol_id, confidence_tier, indexed_at)
                                VALUES (?, ?, ?, ?, ?, ?)
                                """,
                                [.text(edgeID), .text(projectID), .text(caller.id), .text(target.id), .text("lexical_fallback"), .text(indexedAt)]
                            )
                        }
                    }
                }
            }
        }
    }

    func exactLSPReferences(
        symbolName: String,
        root: URL,
        projectID: String,
        limit: Int
    ) throws -> [BurnBarProjectCodeReference] {
        guard let helperPath = Self.staticParserExecutablePath() else { return [] }
        let target = try databaseSync {
            try querySymbols(
                """
                SELECT s.id, s.artifact_id, a.file_path, s.name, s.kind, s.range_json,
                       s.confidence_tier, s.blob_sha, s.tier_evidence_json
                FROM code_symbols s
                JOIN code_artifacts a ON a.id = s.artifact_id
                WHERE s.project_id = ? AND s.name = ?
                ORDER BY
                    CASE WHEN s.confidence_tier = 'exact_lsp' THEN 0
                         WHEN s.confidence_tier = 'static_tree_sitter' THEN 1
                         ELSE 2 END,
                    a.file_path ASC
                LIMIT 1
                """,
                [.text(projectID), .text(symbolName)]
            ).first
        }
        guard let target,
              Self.isCurrentBlob(root: root, filePath: target.filePath, blobSHA: target.blobSHA) else {
            return []
        }
        let fileURL = root.appendingPathComponent(target.filePath, isDirectory: false)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let request = StaticParserRequest(
            requestId: "refs:\(symbolName)",
            filePath: target.filePath,
            language: Self.language(for: fileURL),
            blobSha: target.blobSHA,
            text: text,
            rootPath: root.path,
            operation: "references",
            position: StaticParserPosition(
                line: max(0, target.range.startLine - 1),
                character: max(0, (target.range.startColumn ?? 1) - 1)
            )
        )
        guard let payload = try? JSONEncoder().encode(request) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        guard Self.runHelperProcess(process, input: input, payload: payload) else {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard outputData.count <= Self.codeHelperMaxOutputBytes() else { return [] }
        guard let line = String(data: outputData, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first,
            let response = try? JSONDecoder().decode(StaticParserResponse.self, from: Data(line.utf8)),
            response.ok,
            response.blobSha == target.blobSHA,
            response.errors.isEmpty,
            let refs = response.references,
            refs.isEmpty == false
        else {
            return []
        }
        let capped = max(1, min(limit, 200))
        return refs.prefix(capped).enumerated().map { index, ref in
            let range = BurnBarProjectCodeRange(
                startLine: max(1, ref.startLine),
                endLine: max(max(1, ref.startLine), ref.endLine),
                startColumn: ref.startCharacter + 1,
                endColumn: ref.endCharacter + 1
            )
            let id = "lsp_ref_" + String(Self.sha256Hex("\(projectID):\(symbolName):\(ref.filePath):\(index)").prefix(32))
            return BurnBarProjectCodeReference(
                referenceID: id,
                fromFilePath: ref.filePath,
                targetSymbol: Self.publicSymbol(target),
                range: range,
                confidenceTier: ref.confidenceTier
            )
        }
    }
}
