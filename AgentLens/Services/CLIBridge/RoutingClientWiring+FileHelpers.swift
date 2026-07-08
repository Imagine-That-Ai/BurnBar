import Foundation

extension RoutingClientWiring {

    // MARK: - JSON file helpers

    func readJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let stripped = stripJSONComments(String(decoding: data, as: UTF8.self))
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any]) ?? [:]
    }

    func loadJSONObjectWithBackup(at url: URL) throws -> (root: [String: Any], backupURL: URL?) {
        guard fileManager.fileExists(atPath: url.path) else {
            return ([:], nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RoutingClientWiringError.configReadFailed(path: url.path, detail: error.localizedDescription)
        }
        let stripped = stripJSONComments(String(decoding: data, as: UTF8.self))
        let object: [String: Any]
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object = [:]
        } else {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else { // try?-ok(guard rethrows explicit error)
                throw RoutingClientWiringError.configReadFailed(
                    path: url.path,
                    detail: "could not parse JSON"
                )
            }
            object = parsed
        }
        let backupURL = try backupIfExists(url: url)
        return (object, backupURL)
    }

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try ensureParentDirectory(of: url)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw RoutingClientWiringError.configWriteFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    private func stripJSONComments(_ source: String) -> String {
        // Claude Code's settings.json sometimes ships with `//` comments.
        // Strip them defensively before parsing so we don't lose user edits.
        var result = ""
        result.reserveCapacity(source.count)
        var inString = false
        var iterator = source.makeIterator()
        var lookahead: Character?
        while let ch = lookahead ?? iterator.next() {
            lookahead = nil
            if ch == "\\", let nextChar = iterator.next() {
                result.append(ch)
                result.append(nextChar)
                continue
            }
            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                continue
            }
            if !inString, ch == "/" {
                guard let next = iterator.next() else {
                    result.append(ch)
                    break
                }
                if next == "/" {
                    while let c = iterator.next(), c != "\n" { _ = c }
                    result.append("\n")
                    continue
                }
                if next == "*" {
                    var prev: Character?
                    while let c = iterator.next() {
                        if prev == "*" && c == "/" { break }
                        prev = c
                    }
                    continue
                }
                result.append(ch)
                lookahead = next
                continue
            }
            result.append(ch)
        }
        return result
    }

    // MARK: - Text file helpers

    func readText(at url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8) // try?-ok(nil read handled by callers)
    }

    func writeText(_ text: String, to url: URL) throws {
        try ensureParentDirectory(of: url)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw RoutingClientWiringError.configWriteFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    func stripSentinelBlock(in source: String) -> String {
        guard let startRange = source.range(of: Self.sentinelStart) else { return source }
        guard let endRange = source.range(of: Self.sentinelEnd, range: startRange.upperBound..<source.endIndex) else {
            // Sentinel start without end — bail out and leave the file alone
            // rather than corrupt it.
            return source
        }
        var stripped = source
        stripped.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
        // Collapse the trailing newline left from the removed block.
        while stripped.hasSuffix("\n\n") {
            stripped.removeLast()
        }
        return stripped
    }

    func stripOpenBurnBarLegacyCodexSections(in source: String) -> String {
        var output: [String] = []
        var block: [String] = []

        func flush() {
            guard !block.isEmpty else { return }
            let header = block.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = block.joined(separator: "\n").lowercased()
            let isLegacyOpenBurnBarProfile = header == "[profiles.openburnbar]"
                && text.contains("model_provider")
                && text.contains("openburnbar")
            let isLegacyOpenBurnBarProvider = header == "[model_providers.openburnbar]"
                && text.contains("base_url")
            if !isLegacyOpenBurnBarProfile && !isLegacyOpenBurnBarProvider {
                output.append(contentsOf: block)
            }
            block.removeAll(keepingCapacity: true)
        }

        for line in source.components(separatedBy: "\n") {
            if isTOMLSectionHeader(line) {
                flush()
            }
            block.append(line)
        }
        flush()
        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeVibeProxyEnvironmentKeys(from env: inout [String: Any]) {
        for key in Array(env.keys) {
            let normalizedKey = key.uppercased()
            let value = (env[key] as? String)?.lowercased() ?? ""
            if normalizedKey.contains("VIBEPROXY")
                || normalizedKey.contains("CLI_PROXY")
                || value.contains("vibeproxy")
                || value.contains("cli-proxy-api") {
                env.removeValue(forKey: key)
            }
        }
    }

    func removeVibeProxyOpenCodeProviders(from providers: inout [String: Any]) {
        for key in Array(providers.keys) {
            guard isVibeProxyOpenCodeProvider(id: key, value: providers[key]) else { continue }
            providers.removeValue(forKey: key)
        }
    }

    private func isVibeProxyOpenCodeProvider(id: String, value: Any?) -> Bool {
        let lowercasedID = id.lowercased()
        if lowercasedID.contains("vibeproxy") || lowercasedID.contains("cli-proxy") {
            return true
        }
        guard let dictionary = value as? [String: Any] else { return false }
        let lowercased = lowercasedJSONText(dictionary)
        return lowercased.contains("vibeproxy")
            || lowercased.contains("cli-proxy-api")
            || lowercased.contains("http://localhost:8317")
            || lowercased.contains("http://127.0.0.1:8317")
    }

    func stripVibeProxyTOMLSections(
        in source: String,
        sectionPrefixes: [String]
    ) -> String {
        var output: [String] = []
        var block: [String] = []

        func flush() {
            guard !block.isEmpty else { return }
            if !isVibeProxyTOMLSection(block, sectionPrefixes: sectionPrefixes) {
                output.append(contentsOf: block)
            }
            block.removeAll(keepingCapacity: true)
        }

        for line in source.components(separatedBy: "\n") {
            if isTOMLSectionHeader(line) {
                flush()
            }
            block.append(line)
        }
        flush()

        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stripVibeProxyArrayTOMLBlocks(
        in source: String,
        arrayHeader: String
    ) -> String {
        var output: [String] = []
        var block: [String] = []
        let normalizedArrayHeader = arrayHeader.trimmingCharacters(in: .whitespacesAndNewlines)

        func flush() {
            guard !block.isEmpty else { return }
            let text = block.joined(separator: "\n").lowercased()
            let shouldRemove = block.first?
                .trimmingCharacters(in: .whitespacesAndNewlines) == normalizedArrayHeader
                && (text.contains("vibeproxy")
                    || text.contains("cli-proxy-api")
                    || text.contains("http://localhost:8317")
                    || text.contains("http://127.0.0.1:8317"))
            if !shouldRemove {
                output.append(contentsOf: block)
            }
            block.removeAll(keepingCapacity: true)
        }

        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedArrayHeader {
                flush()
            }
            block.append(line)
        }
        flush()

        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func replaceVibeProxyForgeSessionProvider(in source: String) -> String {
        source.replacingOccurrences(
            of: #"provider_id\s*=\s*"[^"]*vibeproxy[^"]*""#,
            with: #"provider_id = "openburnbar""#,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func isVibeProxyTOMLSection(
        _ block: [String],
        sectionPrefixes: [String]
    ) -> Bool {
        guard let header = block.first else { return false }
        let normalizedHeader = tomlSectionName(header)
        guard sectionPrefixes.contains(where: { normalizedHeader.hasPrefix($0) }) else {
            return false
        }

        let text = block.joined(separator: "\n").lowercased()
        if text.contains("vibeproxy") || text.contains("cli-proxy-api") {
            return true
        }
        if normalizedHeader.hasPrefix("model_providers.")
            || normalizedHeader.hasPrefix("model.") {
            return text.contains("base_url")
                && (text.contains("http://localhost:8317")
                    || text.contains("http://127.0.0.1:8317"))
        }
        return false
    }

    private func isTOMLSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[")
            && trimmed.hasSuffix("]")
            && !trimmed.hasPrefix("[[")
    }

    private func tomlSectionName(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    private func lowercasedJSONText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), // try?-ok(empty string fallback)
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.lowercased()
    }

    func ensureParentDirectory(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw RoutingClientWiringError.configWriteFailed(path: directory.path, detail: error.localizedDescription)
            }
        }
    }

    func backupIfExists(url: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let stamp = backupStamp()
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).openburnbar-backup-\(stamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            return backupURL
        }
        do {
            try fileManager.copyItem(at: url, to: backupURL)
        } catch {
            throw RoutingClientWiringError.backupFailed(path: url.path, detail: error.localizedDescription)
        }
        return backupURL
    }

    private func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: now())
    }
}

extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
