import Foundation

struct CLIExecutableResolver: Sendable {
    fileprivate struct CacheKey: Hashable, Sendable {
        let name: String
        let homeDirectory: String
        let path: String
        let shell: String
    }

    private static let cache = ExecutableResolverCache()

    private let environmentProvider: @Sendable () -> [String: String]
    private let homeDirectoryProvider: @Sendable () -> String

    init(
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectoryProvider: @escaping @Sendable () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }
    ) {
        self.environmentProvider = environmentProvider
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    func resolveExecutable(named name: String) async -> String? {
        await Task.detached {
            let env = environmentProvider()
            let homeDirectory = homeDirectoryProvider()
            let fileManager = FileManager.default
            let cacheKey = CacheKey(
                name: name,
                homeDirectory: homeDirectory,
                path: env["PATH"] ?? "",
                shell: env["SHELL"] ?? ""
            )

            if let cachedPath = Self.cache.value(for: cacheKey),
               fileManager.isExecutableFile(atPath: cachedPath) {
                return cachedPath
            }

            if let path = Self.resolveExecutable(
                named: name,
                searchDirectories: Self.baseExecutableSearchDirectories(
                    environment: env,
                    homeDirectory: homeDirectory
                ),
                fileManager: fileManager
            ) {
                Self.cache.set(path, for: cacheKey)
                return path
            }

            if let path = Self.resolveExecutable(
                named: name,
                searchDirectories: Self.userManagedExecutableSearchDirectories(
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                ),
                fileManager: fileManager
            ) {
                Self.cache.set(path, for: cacheKey)
                return path
            }

            if let path = Self.resolveExecutableFromLoginShell(
                named: name,
                environment: env,
                fileManager: fileManager
            ) {
                Self.cache.set(path, for: cacheKey)
                return path
            }

            return nil
        }.value
    }

    static func clearCache() {
        cache.clear()
    }

    static func baseExecutableSearchDirectories(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return deduplicatedDirectories(pathEntries + [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ], homeDirectory: homeDirectory)
    }

    static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.mise/shims"
        ]

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.nvm/versions/node",
                appending: "/bin",
                fileManager: fileManager
            )
        )

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.fnm/node-versions",
                appending: "/installation/bin",
                fileManager: fileManager
            )
        )

        return deduplicatedDirectories(directories, homeDirectory: homeDirectory)
    }

    static func resolveExecutable(
        named name: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        let shellPath = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard fileManager.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "command -v -- \(shellQuoted(name)) 2>/dev/null"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let path = parseExecutablePath(fromCommandOutput: output),
              fileManager.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }

    static func parseExecutablePath(fromCommandOutput output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { $0.hasPrefix("/") })
    }

    static func enrichedProcessEnvironment(executablePath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let homeDirectory = NSHomeDirectory()
        var extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(homeDirectory)/.local/bin",
        ]

        if let executablePath {
            let executableDirectory = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            extra.insert(executableDirectory, at: 0)
        }

        extra.append(contentsOf: userManagedExecutableSearchDirectories(homeDirectory: homeDirectory))

        let existing = env["PATH"] ?? ""
        let merged = extra + existing.split(separator: ":").map(String.init)
        env["PATH"] = deduplicatedDirectories(merged, homeDirectory: homeDirectory).joined(separator: ":")
        return env
    }

    private static func contentsOfDirectory(
        atPath path: String,
        appending suffix: String,
        fileManager: FileManager
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        return entries
            .sorted(by: >)
            .map { "\(path)/\($0)\(suffix)" }
    }

    private static func deduplicatedDirectories(_ directories: [String], homeDirectory: String) -> [String] {
        var seen = Set<String>()

        return directories.compactMap { directory in
            let expandedHome = directory
                .replacingOccurrences(of: "$HOME", with: homeDirectory)
                .replacingOccurrences(of: "${HOME}", with: homeDirectory)
            let expanded = NSString(string: expandedHome).expandingTildeInPath
            guard !expanded.isEmpty else {
                return nil
            }

            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seen.insert(standardized).inserted else {
                return nil
            }

            return standardized
        }
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private final class ExecutableResolverCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CLIExecutableResolver.CacheKey: String] = [:]

    func value(for key: CLIExecutableResolver.CacheKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, for key: CLIExecutableResolver.CacheKey) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}

extension CLIBridge {
    nonisolated static func baseExecutableSearchDirectories(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        CLIExecutableResolver.baseExecutableSearchDirectories(
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    nonisolated static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        CLIExecutableResolver.userManagedExecutableSearchDirectories(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    nonisolated static func resolveExecutable(
        named name: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> String? {
        CLIExecutableResolver.resolveExecutable(
            named: name,
            searchDirectories: searchDirectories,
            fileManager: fileManager
        )
    }

    nonisolated static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        CLIExecutableResolver.resolveExecutableFromLoginShell(
            named: name,
            environment: environment,
            fileManager: fileManager
        )
    }

    nonisolated static func parseExecutablePath(fromCommandOutput output: String) -> String? {
        CLIExecutableResolver.parseExecutablePath(fromCommandOutput: output)
    }
}
