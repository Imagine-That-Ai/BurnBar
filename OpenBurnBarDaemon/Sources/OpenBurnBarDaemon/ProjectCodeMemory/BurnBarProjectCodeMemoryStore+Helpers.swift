import CryptoKit
import Darwin
import Foundation
import OpenBurnBarCore

extension BurnBarProjectCodeMemoryStore {
    static func projectIndexSignature(root: URL, maxFiles: Int) -> String {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var parts: [String] = enumerateIndexableFiles(root: canonicalRoot, maxFiles: maxFiles).compactMap { url in
            guard let relative = relativePath(url, root: canonicalRoot),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return [
                relative,
                String(values.fileSize ?? 0),
                String(format: "%.6f", values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            ].joined(separator: ":")
        }
        parts.append(contentsOf: gitReferenceSignatureParts(root: canonicalRoot))
        return sha256Hex(parts.sorted().joined(separator: "\n"))
    }

    static func gitReferenceSignatureParts(root: URL) -> [String] {
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: false)
        guard FileManager.default.fileExists(atPath: gitDirectory.path) else { return [] }
        var parts: [String] = []
        let head = gitDirectory.appendingPathComponent("HEAD", isDirectory: false)
        if let data = try? Data(contentsOf: head), let text = String(data: data, encoding: .utf8) {
            parts.append("git:HEAD:\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let refs = gitDirectory.appendingPathComponent("refs", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(
            at: refs,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let relative = relativePath(url, root: gitDirectory) else {
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                parts.append([
                    "git",
                    relative,
                    String(values?.fileSize ?? 0),
                    String(format: "%.6f", values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                ].joined(separator: ":"))
            }
        }
        return parts
    }

    static func secretLabels(in text: String) -> [String] {
        let patterns: [(String, String)] = [
            (#"\bsk-[A-Za-z0-9_\-]{20,}\b"#, "OpenAI API key detected"),
            (#"\bsk-ant-[A-Za-z0-9_\-]{20,}\b"#, "Anthropic API key detected"),
            (#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\b"#, "Stripe secret key detected"),
            (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{30,}\b"#, "GitHub token detected"),
            (#"\bAIza[0-9A-Za-z_\-]{35}\b"#, "Google API key detected"),
            (#"\bxox[baprs]-[A-Za-z0-9\-]{10,}\b"#, "Slack token detected"),
            (#"\bxai-[A-Za-z0-9_\-]{20,}\b"#, "xAI API key detected"),
            (#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, "AWS access key detected"),
            (#"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "Private key block detected"),
            (#"\b[a-z][a-z0-9+.\-]*://[^/\s:@]+:[^@\s]+@[^/\s]+"#, "Database URI credentials detected"),
            (#"\b(?:api[_-]?key|secret|token|password|passwd)\s*[:=]\s*["']?[^"'\s]{32,}"#, "Generic long secret assignment detected"),
            (#"(?m)^\s*[A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD)\s*=\s*[^#\n]{16,}"#, "Dotenv secret assignment detected"),
            (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#, "JWT detected"),
            (#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, "Email address detected"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "IPv4 address detected"),
            (#"\b(?:\d[ -]*?){13,19}\b"#, "Credit card number detected"),
            (#"\b\d{3}-\d{2}-\d{4}\b"#, "US SSN detected"),
            (#"\b(?:\+1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b"#, "US phone number detected")
        ]
        var labels: [String] = []
        for (pattern, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) != nil, labels.contains(label) == false {
                labels.append(label)
            }
        }
        return labels
    }

    static func enumerateIndexableFiles(root: URL, maxFiles: Int) -> [URL] {
        let patterns = gitignorePatterns(root: root)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if files.count >= maxFiles { break }
            guard let relativePath = relativePath(url, root: canonicalRoot) else {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if let resource = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
               resource.isDirectory == true {
                if ignoredDirectories.contains(url.lastPathComponent) || isIgnored(relativePath, isDirectory: true, patterns: patterns) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isIgnored(relativePath, isDirectory: false, patterns: patterns) { continue }
            let ext = url.pathExtension.lowercased()
            guard indexedExtensions.contains(ext) else { continue }
            guard isWithinRoot(url.resolvingSymlinksInPath().standardizedFileURL, root: canonicalRoot) else { continue }
            files.append(url)
        }
        return files
    }

    static func language(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "swift": return "swift"
        case "kt", "kts": return "kotlin"
        case "java": return "java"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "js", "jsx": return "javascript"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "m", "mm", "h", "hpp", "c", "cc", "cpp": return "cpp"
        case "json": return "json"
        case "md": return "markdown"
        case "yml", "yaml": return "yaml"
        default: return nil
        }
    }

    static func relativePath(_ fileURL: URL, root: URL) -> String? {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        let path = canonicalFile.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
    }

    static func chunk(text: String, maxCharacters: Int) -> [CodeChunk] {
        guard text.isEmpty == false else { return [] }
        var chunks: [CodeChunk] = []
        var offset = 0
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            let slice = String(text[index..<end])
            let endOffset = offset + slice.count
            chunks.append(CodeChunk(text: slice, startOffset: offset, endOffset: endOffset, contentHash: sha256Hex(slice)))
            offset = endOffset
            index = end
        }
        return chunks
    }

    static func extractSymbols(
        text: String,
        lang: String?,
        relativePath: String,
        rootPath: String,
        projectID: String,
        artifactID: String,
        blobSHA: String
    ) -> [ExtractedSymbol] {
        if let staticSymbols = staticTreeSitterSymbols(
            text: text,
            lang: lang,
            relativePath: relativePath,
            rootPath: rootPath,
            projectID: projectID,
            artifactID: artifactID,
            blobSHA: blobSHA
        ), staticSymbols.isEmpty == false {
            return staticSymbols
        }

        let language = lang ?? ""
        let patterns: [(String, String)] =
            if language == "python" {
                [(#"^\s*(?:async\s+def|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#, "function"),
                 (#"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)"#, "class")]
            } else if language == "typescript" || language == "javascript" {
                [(#"\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)"#, "function"),
                 (#"\bclass\s+([A-Za-z_$][A-Za-z0-9_$]*)"#, "class"),
                 (#"\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*="#, "variable"),
                 (#"\b(?:interface|type)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#, "type")]
            } else {
                [(#"\b(?:public|private|internal|fileprivate|open)?\s*(?:final\s+)?(?:class|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#, "type"),
                 (#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, "function"),
                 (#"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"#, "variable")]
            }
        let regexes = patterns.compactMap { pattern, kind -> (NSRegularExpression, String)? in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, kind)
        }
        var symbols: [ExtractedSymbol] = []
        for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for (regex, kind) in regexes {
                guard let match = regex.firstMatch(in: line, range: range),
                      match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: line) else { continue }
                let name = String(line[nameRange])
                let lineNumber = lineIndex + 1
                let id = "sym_" + String(sha256Hex("\(projectID):\(artifactID):\(name):\(lineNumber)").prefix(32))
                symbols.append(
                    ExtractedSymbol(
                        id: id,
                        projectID: projectID,
                        artifactID: artifactID,
                        blobSHA: blobSHA,
                        name: name,
                        kind: kind,
                        range: BurnBarProjectCodeRange(startLine: lineNumber, endLine: lineNumber),
                        confidenceTier: "lexical_fallback",
                        tierEvidenceJSON: lexicalTierEvidenceJSON(language: language, blobSHA: blobSHA)
                    )
                )
                break
            }
        }
        _ = relativePath
        return symbols
    }

    static func staticTreeSitterSymbols(
        text: String,
        lang: String?,
        relativePath: String,
        rootPath: String,
        projectID: String,
        artifactID: String,
        blobSHA: String
    ) -> [ExtractedSymbol]? {
        guard ["swift", "typescript", "tsx", "python"].contains(lang ?? ""),
              let helperPath = staticParserExecutablePath() else {
            return nil
        }
        let request = StaticParserRequest(
            requestId: artifactID,
            filePath: relativePath,
            language: lang,
            blobSha: blobSHA,
            text: text,
            rootPath: rootPath
        )
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        let input = Pipe()
        let output = Pipe()
        let stderr = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        do {
            try process.run()
            input.fileHandleForWriting.write(payload)
            input.fileHandleForWriting.write(Data("\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: outputData, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first,
            let response = try? JSONDecoder().decode(StaticParserResponse.self, from: Data(line.utf8)),
            response.ok,
            response.blobSha == blobSHA,
            response.filePath == relativePath,
            response.errors.isEmpty
        else {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            return nil
        }
        let language = response.language
        return response.symbols.map { symbol in
            let range = BurnBarProjectCodeRange(
                startLine: max(1, symbol.startLine),
                endLine: max(max(1, symbol.startLine), symbol.endLine)
            )
            let id = "sym_" + String(sha256Hex("\(projectID):\(artifactID):\(symbol.name):\(range.startLine)").prefix(32))
            let evidence = BurnBarProjectCodeTierEvidence(
                parser: symbol.evidence.parser ?? "tree-sitter",
                language: symbol.evidence.language ?? language,
                blobSHA: symbol.evidence.blobSha ?? response.blobSha,
                shaMatch: symbol.evidence.shaMatch ?? true,
                lspResponded: symbol.evidence.lspResponded,
                details: [
                    "helper": "project-code-static-parser",
                    "parseError": response.hasParseError ? "true" : "false"
                ]
            )
            return ExtractedSymbol(
                id: id,
                projectID: projectID,
                artifactID: artifactID,
                blobSHA: blobSHA,
                name: symbol.name,
                kind: symbol.kind,
                range: range,
                confidenceTier: symbol.confidenceTier,
                tierEvidenceJSON: tierEvidenceJSON(evidence)
            )
        }
    }

    static func staticParserExecutablePath() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["OPENBURNBAR_CODE_STATIC_PARSER_PATH"], configured.isEmpty == false {
            candidates.append(configured)
        }
        let cwd = fileManager.currentDirectoryPath
        candidates.append("\(cwd)/crates/project-code-static-parser/target/release/project-code-static-parser")
        candidates.append("\(cwd)/crates/project-code-static-parser/target/debug/project-code-static-parser")
        candidates.append("\(cwd)/../crates/project-code-static-parser/target/release/project-code-static-parser")
        candidates.append("\(cwd)/../crates/project-code-static-parser/target/debug/project-code-static-parser")
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func lexicalTierEvidenceJSON(language: String, blobSHA: String) -> String? {
        tierEvidenceJSON(
            BurnBarProjectCodeTierEvidence(
                parser: "regex",
                language: language.isEmpty ? nil : language,
                blobSHA: blobSHA,
                shaMatch: true,
                lspResponded: false,
                details: ["fallback": "static parser unavailable or unsupported"]
            )
        )
    }

    static func tierEvidenceJSON(_ evidence: BurnBarProjectCodeTierEvidence) -> String? {
        guard let data = try? JSONEncoder().encode(evidence) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeRange(_ json: String) -> BurnBarProjectCodeRange {
        (try? JSONDecoder().decode(BurnBarProjectCodeRange.self, from: Data(json.utf8)))
            ?? BurnBarProjectCodeRange(startLine: 1, endLine: 1)
    }

    static func ftsQuery(for query: String) -> String {
        let tokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
            .filter { $0.isEmpty == false }
        guard tokens.isEmpty == false else {
            return "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }

    static func identifierTokens(in line: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for scalar in line.unicodeScalars {
            let value = scalar.value
            let isIdentifier =
                (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57)
                || value == 95
            if isIdentifier {
                current.unicodeScalars.append(scalar)
            } else if current.isEmpty == false {
                if current.count >= 3 { tokens.insert(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 3 { tokens.insert(current) }
        return tokens
    }

    static func searchTokens(in query: String) -> [String] {
        let tokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
            .filter { $0.isEmpty == false }
        return Array(Set(tokens)).sorted()
    }

    static func memoryRank(tokens: [String], query: String, searchable: String) -> Double? {
        let haystack = searchable.lowercased()
        let needles = tokens.isEmpty ? [query.lowercased()] : tokens
        let matchCount = needles.filter { haystack.contains($0) }.count
        guard matchCount > 0 else { return nil }
        return Double(needles.count - matchCount)
    }

    static func memorySnippet(body: String, tokens: [String], fallbackQuery: String) -> String {
        let lower = body.lowercased()
        let needles = tokens.isEmpty ? [fallbackQuery.lowercased()] : tokens
        guard let token = needles.first(where: { lower.contains($0) }),
              let range = lower.range(of: token) else {
            return String(body.prefix(240))
        }
        let distanceBefore = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let distanceAfter = lower.distance(from: range.upperBound, to: lower.endIndex)
        let start = body.index(body.startIndex, offsetBy: max(0, distanceBefore - 80))
        let end = body.index(body.endIndex, offsetBy: -max(0, distanceAfter - 160))
        let prefix = start > body.startIndex ? "..." : ""
        let suffix = end < body.endIndex ? "..." : ""
        return prefix + String(body[start..<end]) + suffix
    }

    static func gitCommitSHA(root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        } catch {
            return nil
        }
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func gitBlobSHA(_ data: Data) -> String {
        var payload = Data("blob \(data.count)\0".utf8)
        payload.append(data)
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    static func gitignorePatterns(root: URL) -> [String] {
        let url = root.appendingPathComponent(".gitignore", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false && $0.hasPrefix("!") == false }
    }

    static func isIgnored(_ relativePath: String, isDirectory: Bool, patterns: [String]) -> Bool {
        let pathComponents = relativePath.split(separator: "/").map(String.init)
        if pathComponents.contains(where: { ignoredDirectories.contains($0) }) {
            return true
        }
        for rawPattern in patterns {
            let directoryPattern = rawPattern.hasSuffix("/")
            let pattern = rawPattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if pattern.isEmpty { continue }
            if directoryPattern {
                if isDirectory, wildcardMatches(pattern, relativePath) || pathComponents.contains(where: { wildcardMatches(pattern, $0) }) {
                    return true
                }
                if relativePath.hasPrefix(pattern + "/") || relativePath.contains("/" + pattern + "/") {
                    return true
                }
                continue
            }
            if wildcardMatches(pattern, relativePath)
                || wildcardMatches(pattern, URL(fileURLWithPath: relativePath).lastPathComponent)
                || wildcardMatches("*/" + pattern, relativePath) {
                return true
            }
        }
        return false
    }

    static func wildcardMatches(_ pattern: String, _ value: String) -> Bool {
        fnmatch(pattern, value, 0) == 0
    }

    static func isWithinRoot(_ fileURL: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return fileURL.path.hasPrefix(rootPath)
    }

    static func isCurrentBlob(root: URL, filePath: String, blobSHA: String) -> Bool {
        guard blobSHA.isEmpty == false else { return false }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let fileURL = canonicalRoot.appendingPathComponent(filePath, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isWithinRoot(fileURL, root: canonicalRoot), let data = try? Data(contentsOf: fileURL) else {
            return false
        }
        return gitBlobSHA(data) == blobSHA
    }
}
