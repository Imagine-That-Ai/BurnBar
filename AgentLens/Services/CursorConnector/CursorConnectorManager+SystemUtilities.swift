import Foundation

extension CursorConnectorManager {
    nonisolated static func findExecutable(named name: String) -> String? {
        if let path = runWhich(named: name) { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.homebrew/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    nonisolated static func findHomebrew() -> String? {
        if let path = runWhich(named: "brew") { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.homebrew/bin/brew",
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    nonisolated private static func runWhich(named name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    static func runCommand(executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CursorConnector", code: 15, userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    static func extractTryCloudflareURL(from text: String) -> String? {
        for token in text.split(whereSeparator: \.isWhitespace) {
            let candidate = token.trimmingCharacters(in: .tryCloudflareURLDelimiters)
            guard
                let components = URLComponents(string: String(candidate)),
                components.scheme?.lowercased() == "https",
                components.user == nil,
                components.password == nil,
                components.port == nil,
                components.path.isEmpty || components.path == "/",
                components.query == nil,
                components.fragment == nil,
                let host = components.host?.lowercased(),
                let encodedHost = components.percentEncodedHost?.lowercased(),
                host == encodedHost,
                Self.isCanonicalTryCloudflareHost(host)
            else {
                continue
            }
            return "https://\(host)"
        }
        return nil
    }

    private static func isCanonicalTryCloudflareHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count == 3,
              labels[1] == "trycloudflare",
              labels[2] == "com",
              let tunnelLabel = labels.first,
              (1...63).contains(tunnelLabel.count) else {
            return false
        }
        guard let first = tunnelLabel.unicodeScalars.first,
              let last = tunnelLabel.unicodeScalars.last,
              Self.isASCIILetterOrNumber(first),
              Self.isASCIILetterOrNumber(last) else {
            return false
        }
        return tunnelLabel.unicodeScalars.allSatisfy { scalar in
            Self.isASCIILetterOrNumber(scalar) || scalar == "-"
        }
    }

    private static func isASCIILetterOrNumber(_ scalar: UnicodeScalar) -> Bool {
        (97...122).contains(scalar.value)
            || (48...57).contains(scalar.value)
    }

    static var isoDateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

}
